{-# OPTIONS_GHC -fno-warn-unused-imports #-} -- This module is intentionally
-- full of imports that will be used by the REPL.
{- | Top-level module for the interpreter in Language.  Everything in this
    module is visible to the REPL, so it imports a lot of potentially useful
    modules.

    It has to be interpreted, so it should just put useful things into scope
    but not actually define anything itself.  Those definitions go in
    Cmd.Lang.Global.
-}
module Cmd.Lang.Environ where
import Control.Monad.Trans (liftIO)
import qualified Data.Map as Map
import qualified Data.List as List
import qualified Data.Set as Set

import Util.Control
import qualified Util.Map as Map
import qualified Util.Log as Log
import qualified Util.PPrint as PPrint
import qualified Util.Pretty as Pretty

import qualified Ui.Block as Block
import qualified Ui.Color as Color
import qualified Ui.Event as Event
import qualified Ui.Id as Id
import qualified Ui.Ruler as Ruler
import qualified Ui.State as State
import qualified Ui.Skeleton as Skeleton
import qualified Ui.Symbol as Symbol
import qualified Ui.Track as Track
import qualified Ui.Types as Types
import qualified Ui.Update as Update

import qualified Midi.Midi as Midi
import qualified Midi.Synth as Synth

import qualified Cmd.Clip as Clip
import qualified Cmd.Cmd as Cmd
import qualified Cmd.Create as Create
import qualified Cmd.Edit as Edit
import qualified Cmd.Info as Info
import qualified Cmd.Integrate as Integrate
import qualified Cmd.Lang.LBlock as LBlock
import qualified Cmd.Lang.LEvent as LEvent
import qualified Cmd.Lang.LInst as LInst
import qualified Cmd.Lang.LPerf as LPerf
import qualified Cmd.Lang.LPitch as LPitch
import qualified Cmd.Lang.LRuler as LRuler
import qualified Cmd.Lang.LState as LState
import qualified Cmd.Lang.LSymbol as LSymbol
import qualified Cmd.Lang.LTrack as LTrack
import qualified Cmd.Lang.LView as LView
import qualified Cmd.MakeRuler as MakeRuler
import qualified Cmd.ModifyEvents as ModifyEvents
import qualified Cmd.Perf as Perf
import qualified Cmd.Play as Play
import qualified Cmd.PlayUtil as PlayUtil
import qualified Cmd.Save as Save
import qualified Cmd.Selection as Selection
import qualified Cmd.Simple as Simple
import qualified Cmd.StepPlay as StepPlay
import qualified Cmd.TimeStep as TimeStep
import qualified Cmd.ViewConfig as ViewConfig

import qualified Derive.Derive as Derive
import qualified Derive.LEvent as LEvent
import qualified Derive.Score as Score
import qualified Perform.Pitch as Pitch
import qualified Perform.Midi.Convert as Convert
import qualified Perform.Midi.Instrument as Instrument
import qualified Perform.Midi.Perform as Perform
import qualified Instrument.Db as Db
import Cmd.Lang.Global

import qualified App.Config as Config
import Types

-- -- hint is now insisting these be in scope or the types from 'run' aren't
-- -- found.  It smells like a bug to me...
-- import qualified Cmd.Cmd
-- import qualified Midi.Midi
-- import qualified Util.Log
-- import qualified Ui.State
-- import qualified Ui.Update
-- import qualified Ui.Block


-- | Like 'Cmd.run', but pretty-print the return value.  If the value is
-- already a string, just return it unchanged.
--
-- This is automatically added to language text by Language.mangle_text so it
-- can pretend to be running in the "real" CmdT.
run :: Show a => Cmd.CmdL a -> State.State -> Cmd.State
    -> IO (Cmd.CmdVal String)
run cmd ui_state cmd_state =
    Cmd.run "" ui_state cmd_state (fmap PPrint.str_pshow cmd)
