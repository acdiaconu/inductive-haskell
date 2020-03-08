{-# LANGUAGE TemplateHaskell #-}

module Search where

import Elements
import Data.List
import Language.Syntax 
import Language.Environment
import Language.Types
import Language.Infer
import Data.Maybe
import Debug.Trace
import Data.Char
import qualified Data.Map as Map
import qualified Data.Set as Set
import DepGraph

import Control.Monad.State

-- progSearch :: (IProgram -> Bool) -> 
--               ((IProgram, ProgInfo) -> [(IProgram, ProgInfo)]) -> 
--               ProgInfo -> Maybe ProgInfo
-- progSearch check next initInfo = 
--     selectFirstResult (\d -> (trace ("Searching at depth " ++ show d ++ "...")) dbSearch d check next initInfo) [0 .. ]
--     where dbSearch d check next crtState
--             | d == 0             = Nothing
--             | check crtState == True  = Just crt
--             | check crtState == False = selectFirstResult (dbSearch (d - 1) check next) (map next (combine crtState))
--           selectFirstResult select [] = Nothing
--           selectFirstResult select (xm:xms) =
--             case select xm of
--                 Nothing -> selectFirstResult select xms
--                 Just x  -> Just x

expand :: (IProgram, ProgInfo) -> [(IProgram, ProgInfo)]
expand (ip, pinf) = foldl filterJusts [] stream
    where
        (defn, newIProg) = popCand ip
        specDefs = map applyMr (zip (repeat defn) (mrs pinf))
        onlyNames = [ name | (name, _) <- envToList (env pinf), head name == '_' ]
        stream = [ fill pinf def cProd | 
                    (def, nHoles) <- specDefs,
                    cProd <- sequence ((take nHoles . repeat) onlyNames)
                 ]
        filterJusts ls mb = case mb of
            Nothing -> ls
            Just (d, pi) -> ((pushDefn d newIProg), pi):ls

applyMr :: (Defn, Metarule) -> (Defn, Int)
applyMr ((Val name expr), mr) = 
    case expr of 
        Empty -> (Val name (body mr), nargs mr)
        _     -> error "When assigning mrs, the body should be empty"

fill :: ProgInfo -> Defn -> [Name] -> Maybe (Defn, ProgInfo)
fill pinf (Val name body) withs = do
    (sch, _, populated) <- runInfer $ inferDef (env pinf) (Val name body) (Just withs)
    newG <- foldM addEdge (fDepG pinf) (zip (repeat name) withs)
    let newPinf = pinf {
        env = define (env pinf) name sch,
        fDepG = newG
    }
    return (Val name populated, newPinf)




-- --- for expansion of nodes

-- inferTypes :: State ProgInfo ()
-- inferTypes state = 
--     where myIncomplete = selectIncompelte ip 

-- expand (prog, (mp, fp, fc, cnt)) 
--     | hasMetarule prog = if isCompleteIP prog
--                          then []
--                          else zipWith (\(p, cnt, newFP, newFC) m -> (p, (m, newFP, newFC, cnt))) (specialize prog MEmpty fp fc cnt) (repeat mp)
--     | otherwise        = (concat.map create) [0 .. (length mp) - 1]
--     where create idx = let progs = specialize prog (mp !! idx) fp fc cnt in
--                        zipWith (\(p, cnt, newFP, newFC) m -> (p, (m, newFP, newFC, cnt))) progs (repeat mp)

-- specialize :: IProgram -> Metarule -> FunctionContext -> FuncDepGraph -> Int -> [(IProgram, Int, FunctionContext, FuncDepGraph)]
-- specialize (IProgram [] cs) mr fp fc cnt = [(IProgram [] cs, cnt, fp, fc)]
-- specialize (IProgram (i:is) cs) mr fp fc cnt = map createIPs (fill i mr fp fc [] cnt) 
--     where createIPs (fun, cnt, subst, newFP, newFC) = 
--             ((IProgram (map (applyConstIF subst) (takeIncomp fun) ++ map (applyConstIF subst) is) (takeComp fun ++ cs)), 
--              cnt, 
--              map (\(n, t) -> (n, applySubst subst t)) newFP,
--              newFC)
--           takeComp fun = takeWhile isCompleteIF fun
--           takeIncomp fun = dropWhile isCompleteIF fun

-- applyConstIF :: Substitution -> IFunction -> IFunction
-- applyConstIF subst ifn = 
--     case ifn of
--         Incomplete name mr t fofs -> 
--             Incomplete name mr (applySubst subst t) (applyForFofs fofs subst)
--         Complete name mr t fofs ->
--             Complete name mr (applySubst subst t) (applyForFofs fofs subst)
--     where applyForFofs fofs subst = map (apply subst) fofs
--           apply subst (FOF a) = FOF a
--           apply subst (FEmpty t) = FEmpty (applySubst subst t)

-- mrType :: Metarule -> Int -> ([Type], Type)
-- mrType COMP cnt = ([Arrow [(TVar ('b':[show cnt]))] (TVar ('c':[show cnt])), 
--                     Arrow [(TVar ('a':[show cnt]))] (TVar ('b':[show cnt]))],
--                   (Arrow [TVar ('a':[show cnt])] (TVar ('c':[show cnt]))))
-- mrType MAP cnt = ([Arrow [TVar ('a':[show cnt])] (TVar ('b':[show cnt]))],
--                   Arrow [TArray (TVar ('a':[show cnt]))] (TArray (TVar ('b':[show cnt]))))
-- mrType FILTER cnt = ([Arrow [TVar ('a':[show cnt])] (BaseType 'Bool')],
--                      Arrow [TArray (TVar ('a':[show cnt]))] (TArray (TVar ('a':[show cnt]))))

-- fill :: IFunction -> Metarule -> FunctionContext -> FuncDepGraph -> [FOF] -> Int -> [([IFunction], Int, Substitution, FunctionContext, FuncDepGraph)]
-- fill (Incomplete name MEmpty ift []) mr fp fc _ cnt = 
--     case subst of
--         Just s -> [([Incomplete name mr ift fPhs], cnt + 1, s, fp, fc)]
--         Nothing -> []
--     where (inputs, output) = mrType mr cnt
--           subst = unify ift output
--           fPhs = map (\t -> FEmpty t) inputs

-- fill (Incomplete name mr ift ((FEmpty fType):xs)) _ fp fc prev cnt =
--     onlyPossible fp ++ 
--     [([Incomplete name mr ift (reverse prev ++ (FOF (show cnt):xs)),
--        Incomplete (show cnt) MEmpty fType []],
--        cnt + 1, emptySubst, fp ++ [(show cnt, fType)], fromJust $ addEdge fc (show cnt, name))]
--     where onlyPossible [] = []
--           onlyPossible ((fn, ft):fs) = 
--             let (corrFT, newCnt) = 
--                     if isDigit (head fn) 
--                     then (ft, cnt)
--                     else (freshen cnt ft, cnt + 1)
--             in
--             case unify (generalize fType) corrFT of
--                 Just subst -> 
--                     if isDigit (head fn) && isDigit (head name) 
--                     then 
--                         (case (addEdge fc (fn, name)) of
--                             Just newG -> ([Incomplete name mr ift (reverse prev ++ (FOF fn:xs))], newCnt, subst, fp, newG):(onlyPossible fs)
--                             Nothing -> onlyPossible fs)
--                     else ([Incomplete name mr ift (reverse prev ++ (FOF fn:xs))], newCnt, subst, fp, fc):(onlyPossible fs)
--                 Nothing -> onlyPossible fs

-- fill (Incomplete name mr fType (FOF f:xs)) newMr fp fc prev cnt = 
--     fill (Incomplete name mr fType xs) newMr fp fc (FOF f : prev) cnt
-- fill (Incomplete name mr fType []) _ fp fc prev cnt = [([Complete name mr fType (reverse prev)], cnt, emptySubst, fp, fc)]
-- fill (Complete name m fTyp fofs) _ fp fc _ cnt = [([Complete name m fTyp fofs], cnt, emptySubst, fp, fc)]

-- generalize (Arrow [TArray x] (TArray y)) = Arrow [x] y
-- generalize x = x

-- -- if the metarule is MEmpty, then we can generalize: idea is that
-- -- if we didnt fill the function we might as well generalize a bit just in case