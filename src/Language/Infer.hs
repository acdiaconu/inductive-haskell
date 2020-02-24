{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Language.Infer where

import Prelude hiding (foldr)

import Language.Types
import Language.Syntax
import Language.Environment

import Elements

import Control.Monad.State
import Control.Monad.Trans.Maybe

import Data.Monoid
import Data.List (nub)
import Data.Foldable (foldr)
import qualified Data.Map as Map
import qualified Data.Set as Set

import Debug.Trace

type TEnv = Environment Scheme

data Unique = Unique { count :: Int }

type Infer a = MaybeT (State Unique) a
returnInfer = return
returnFailure = MaybeT $ return Nothing

type Subst = Map.Map Name Type

runInfer :: Infer (Subst, Type) -> Maybe Scheme
runInfer m = case evalState (runMaybeT m) initUnique of
  Nothing -> Nothing
  Just res -> Just $ closeOver res

closeOver :: (Map.Map Name Type, Type) -> Scheme
closeOver (sub, ty) = normalize sc
  where sc = generalize empty_env (apply sub ty)

initUnique :: Unique
initUnique = Unique { count = 0 }

extend :: TEnv -> (Name, Scheme) -> TEnv
extend env (x, s) = define env x s

-- typeof :: TEnv -> Name -> Maybe Scheme
-- typeof env name = define env name

class Substitutable a where
  apply :: Subst -> a -> a
  ftv   :: a -> Set.Set Name

instance Substitutable Type where
  apply _ (BaseType a)    = BaseType a
  apply s t@(TVar a)      = Map.findWithDefault t a s
  apply s (t1 `Arrow` t2) = apply s t1 `Arrow` apply s t2
  apply s (TTuple tvs)    = TTuple (map (apply s) tvs)
  apply s (TArray t)      = TArray (apply s t)

  ftv (BaseType _)    = Set.empty
  ftv (TVar a)        = Set.singleton a
  ftv (t1 `Arrow` t2) = ftv t1 `Set.union` ftv t2
  ftv (TArray t)      = ftv t
  ftv (TTuple tvs)    = foldl (\set t -> set `Set.union` (ftv t)) Set.empty tvs

instance Substitutable Scheme where
  apply s (Forall as t) = Forall as $ apply s' t
                          where s' = foldr Map.delete s as
  ftv (Forall as t) = ftv t `Set.difference` Set.fromList as

instance Substitutable a => Substitutable [a] where
  apply = fmap . apply
  ftv   = foldr (Set.union . ftv) Set.empty

instance Substitutable TEnv where
  apply s env = envMap env (apply s)
  ftv env = ftv $ envElems env

nullSubst :: Subst
nullSubst = Map.empty

compose :: Subst -> Subst -> Subst
s1 `compose` s2 = s1 `Map.union` Map.map (apply s1) s2

unify ::  Type -> Type -> Infer Subst
unify (l `Arrow` r) (l' `Arrow` r')  = do
  s1 <- unify l l'
  s2 <- unify (apply s1 r) (apply s1 r')
  return (s2 `compose` s1)
unify (TVar a) t = bind a t
unify t (TVar a) = bind a t
unify (BaseType a) (BaseType b) | a == b = returnInfer nullSubst
unify (TArray t1) (TArray t2) = unify t1 t2
unify (TTuple t1) (TTuple t2) = unifyListsLTR t1 t2
unify _ _ = returnFailure

unifyListsLTR :: [Type] -> [Type] -> Infer Subst
unifyListsLTR t1s t2s = foldM step nullSubst zipped
  where zipped = zip t1s t2s
        step s (t1, t2) = do
          nS <- unify (apply s t1) (apply s t2)
          return (nS `compose` s)

bind ::  Name -> Type -> Infer Subst
bind a t
  | t == TVar a     = returnInfer nullSubst
  | occursCheck a t = returnFailure 
  | otherwise       = returnInfer $ Map.singleton a t

occursCheck ::  Substitutable a => Name -> a -> Bool
occursCheck a t = a `Set.member` ftv t

letters :: [String]
letters = [1..] >>= flip replicateM ['a'..'z']

fresh :: Infer Type
fresh = do
  s <- get
  put s{count = count s + 1}
  return $ TVar $ (letters !! count s)

instantiate ::  Scheme -> Infer Type
instantiate (Forall as t) = do
  as' <- mapM (const fresh) as
  let s = Map.fromList $ zip as as'
  return $ apply s t

generalize :: TEnv -> Type -> Scheme
generalize env t  = Forall as t
  where as = Set.toList $ ftv t `Set.difference` ftv env

lookupEnv :: TEnv -> Name -> Infer (Subst, Type)
lookupEnv env name = do 
  t <- instantiate (find env name)
  returnInfer (nullSubst, t)

infer :: TEnv -> Expr -> Infer (Subst, Type)
infer env ex = case ex of

  Number n -> returnInfer (nullSubst, BaseType "Int")

  Character c -> returnInfer (nullSubst, BaseType "Char")

  Variable v -> lookupEnv env v

  Lambda vs expr -> do
    tvs <- replicateM (length vs) fresh
    let env' = foldl (\ te (tv, v) -> te `extend` (v, Forall [] tv)) env (zip tvs vs)
    (s, t) <- infer env' expr
    return (s, apply s (Arrow (TTuple tvs) t))

  Apply e es -> do
    tv <- fresh
    (s1, t1) <- infer env e
    (ss, ts) <- inferListLTR env es
    s2 <- unify (apply ss t1) (Arrow ts tv)
    return (s2 `compose` ss `compose` s1, apply s2 tv)

  Let (Val x e1) e2 -> do
    (s1, t1) <- infer env e1
    let env' = apply s1 env
        t' = generalize env' t1
    (s2, t2) <- infer (env' `extend` (x, t')) e2
    return (s1 `compose` s2, t2)

  If e1 e2 e3 -> do
    (s1, t1) <- infer env e1
    (s2, t2) <- infer env e2 
    (s3, t3) <- infer env e3
    s4 <- unify t1 (BaseType "Bool")
    s5 <- unify t2 t3
    return (s5 `compose` s4 `compose` s3 `compose` s2 `compose` s1, apply s5 t2)

  Let (Rec x e1) e2 -> do
    nV <- fresh
    let expEnv = env `extend` (x, generalize env nV)
    (s1, t1) <- infer expEnv e1
    let env' = apply s1 expEnv
        t' = generalize env' t1
    (s2, t2) <- infer (env' `extend` (x, t')) e2
    return (s1 `compose` s2, t2)

inferDef :: TEnv -> Defn -> Infer (Subst, Type)
inferDef tenv (Val x body) = do
    (s1, t1) <- infer tenv body
    return (s1, t1)
    
inferDef tenv (Rec x body) = do
    nV <- fresh
    let expEnv = tenv `extend` (x, generalize tenv nV)
    (s1, t1) <- infer expEnv body
    return (s1, t1)

inferListLTR :: TEnv -> [Expr] -> Infer (Subst, Type)
inferListLTR tenv exprs = foldM step (nullSubst, TTuple []) (reverse exprs)
  where step (ns, TTuple ts) e = do
          (s, t) <- infer tenv e
          return (s `compose` ns, TTuple (t:ts))

inferExpr :: TEnv -> Expr -> Maybe Scheme
inferExpr env = runInfer . infer env

inferSynth :: ProgInfo -> Defn -> Maybe (Scheme, ProgInfo)
inferSynth 

normalize :: Scheme -> Scheme
normalize (Forall ts body) = Forall (fmap snd ord) (normtype body)
  where
    ord = zip (nub $ fv body) letters

    fv (TVar a)   = [a]
    fv (Arrow a b) = fv a ++ fv b
    fv (BaseType _)   = []
    fv (TArray t) = fv t
    fv (TTuple ts) = concat [fv t | t <- ts]

    normtype (Arrow a b) = Arrow (normtype a) (normtype b)
    normtype (BaseType a) = BaseType a
    normtype (TVar a) =
      case lookup a ord of
        Just x -> TVar x
        Nothing -> error "type variable not in signature"
    normtype (TArray t) = TArray (normtype t)
    normtype (TTuple ts) = TTuple (map normtype ts)

-- inferTop :: TEnv -> [(String, Expr)] -> Maybe TEnv
-- inferTop env [] = Just env
-- inferTop env ((name, ex):xs) = case inferExpr env ex of
--   Nothing -> Nothing
--   Just ty -> inferTop (extend env (name, ty)) xs

-- inferPrim :: TEnv -> [Expr] -> Type -> Infer (Subst, Type)
-- inferPrim env l t = do
--   tv <- fresh
--   (s1, tf) <- foldM inferStep (nullSubst, id) l
--   s2 <- unify (apply s1 (tf tv)) t
--   return (s2 `compose` s1, apply s2 tv)
--   where
--   inferStep (s, tf) exp = do
--     (s', t) <- infer (apply s env) exp
--     return (s' `compose` s, tf . (Arrow t))