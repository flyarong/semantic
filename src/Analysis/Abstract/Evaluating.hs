{-# LANGUAGE GeneralizedNewtypeDeriving, RankNTypes, TypeFamilies, UndecidableInstances, ScopedTypeVariables #-}
module Analysis.Abstract.Evaluating
( Evaluating
, EvaluatorState(..)
, State
) where

import           Control.Abstract.Analysis
import           Control.Monad.Effect
import           Data.Abstract.Configuration
import           Data.Abstract.Environment as Env
import           Data.Abstract.Evaluatable
import           Data.Abstract.Module
import           Data.Abstract.ModuleTable
import           Data.Abstract.Origin
import qualified Data.IntMap as IntMap
import           Lens.Micro
import           Prelude hiding (fail)
import           Prologue

-- | An analysis evaluating @term@s to @value@s with a list of @effects@ using 'Evaluatable', and producing incremental results of type @a@.
newtype Evaluating location term value effects a = Evaluating (Eff effects a)
  deriving (Applicative, Functor, Effectful, Monad)

deriving instance Member Fail   effects => MonadFail   (Evaluating location term value effects)
deriving instance Member Fresh  effects => MonadFresh  (Evaluating location term value effects)
deriving instance Member NonDet effects => Alternative (Evaluating location term value effects)

-- | Effects necessary for evaluating (whether concrete or abstract).
type EvaluatingEffects location term value
  = '[ Exc (ControlThrow value)
     , Resumable (EvalError value)
     , Resumable (ResolutionError value)
     , Resumable (LoadError term value)
     , Resumable (ValueError location value)
     , Resumable (Unspecialized value)
     , Resumable (AddressError location value)
     , Fail                                        -- Failure with an error message
     , Fresh                                       -- For allocating new addresses and/or type variables.
     , Reader (SomeOrigin term)                    -- The current term’s origin.
     , Reader (ModuleTable [Module term])          -- Cache of unevaluated modules
     , Reader (Environment location value)         -- Default environment used as a fallback in lookupEnv
     , State  (EvaluatorState location term value) -- Environment, heap, modules, exports, and jumps.
     ]

(.=) :: Member (State (EvaluatorState location term value)) effects => ASetter (EvaluatorState location term value) (EvaluatorState location term value) a b -> b -> Evaluating location term value effects ()
lens .= val = raise (modify' (lens .~ val))

view :: Member (State (EvaluatorState location term value)) effects => Getting a (EvaluatorState location term value) a -> Evaluating location term value effects a
view lens = raise (gets (^. lens))

localEvaluatorState :: Member (State (EvaluatorState location term value)) effects => Lens' (EvaluatorState location term value) prj -> (prj -> prj) -> Evaluating location term value effects a -> Evaluating location term value effects a
localEvaluatorState lens f action = do
  original <- view lens
  lens .= f original
  v <- action
  v <$ lens .= original


instance Members '[Fail, State (EvaluatorState location term value)] effects => MonadControl term effects (Evaluating location term value) where
  label term = do
    m <- view _jumps
    let i = IntMap.size m
    _jumps .= IntMap.insert i term m
    pure i

  goto label = IntMap.lookup label <$> view _jumps >>= maybe (fail ("unknown label: " <> show label)) pure

instance Members '[ State (EvaluatorState location term value)
                  , Reader (Environment location value)
                  ] effects
      => MonadEnvironment location value effects (Evaluating location term value) where
  getEnv = view _environment
  putEnv = (_environment .=)
  withEnv s = localEvaluatorState _environment (const s)

  defaultEnvironment = raise ask
  withDefaultEnvironment e = raise . local (const e) . lower

  getExports = view _exports
  putExports = (_exports .=)
  withExports s = localEvaluatorState _exports (const s)

  localEnv f a = do
    modifyEnv (f . Env.push)
    result <- a
    result <$ modifyEnv Env.pop

instance Member (State (EvaluatorState location term value)) effects
      => MonadHeap location value effects (Evaluating location term value) where
  getHeap = view _heap
  putHeap = (_heap .=)

instance Members '[ Reader (ModuleTable [Module term])
                  , State (EvaluatorState location term value)
                  , Reader (SomeOrigin term)
                  , Fail
                  ] effects
      => MonadModuleTable location term value effects (Evaluating location term value) where
  getModuleTable = view _modules
  putModuleTable = (_modules .=)

  askModuleTable = raise ask
  localModuleTable f a = raise (local f (lower a))

  getLoadStack = view _loadStack
  putLoadStack = (_loadStack .=)

  currentModule = do
    o <- raise ask
    maybeFail "unable to get currentModule" $ withSomeOrigin (originModule @term) o

instance Members (EvaluatingEffects location term value) effects
      => MonadEvaluator location term value effects (Evaluating location term value) where
  getConfiguration term = Configuration term mempty <$> getEnv <*> getHeap

instance ( Corecursive term
         , Members (EvaluatingEffects location term value) effects
         , Recursive term
         )
      => MonadAnalysis location term value effects (Evaluating location term value) where
  type Effects location term value (Evaluating location term value) = EvaluatingEffects location term value

  analyzeTerm eval term = pushOrigin (termOrigin (embedSubterm term)) (eval term)

  analyzeModule eval m = pushOrigin (moduleOrigin (subterm <$> m)) (eval m)
