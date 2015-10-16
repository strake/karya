-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Utilities to directly perform a saved score.
module Derive.DeriveSaved where
import qualified Control.Monad.Error as Error
import qualified Data.Text.Lazy as Lazy
import qualified Data.Vector as Vector
import qualified System.FilePath as FilePath
import qualified Text.Printf as Printf

import qualified Util.Log as Log
import qualified Util.Test as Test
import qualified Midi.Midi as Midi
import qualified Midi.StubMidi as StubMidi
import qualified Ui.State as State
import qualified Cmd.Cmd as Cmd
import qualified Cmd.Lilypond
import qualified Cmd.Msg as Msg
import qualified Cmd.Performance as Performance
import qualified Cmd.PlayUtil as PlayUtil
import qualified Cmd.Save as Save
import qualified Cmd.SaveGit as SaveGit

import qualified Derive.Cache as Cache
import qualified Derive.Call.All as Call.All
import qualified Derive.Derive as Derive
import qualified Derive.LEvent as LEvent
import qualified Derive.Scale.All as Scale.All
import qualified Derive.Stream as Stream

import qualified Local.Config
import qualified App.Config as Config
import qualified App.StaticConfig as StaticConfig
import Global
import Types


perform_file :: Cmd.Config -> FilePath -> IO [Midi.WriteMessage]
perform_file cmd_config fname = do
    (ui_state, library) <- either (errorIO . untxt) return =<< load_score fname
    block_id <- maybe (errorIO $ fname <> ": no root block") return $
        State.config#State.root #$ ui_state
    let cmd_state = add_library library (Cmd.initial_state cmd_config)
    (events, logs) <- timed_derive fname ui_state cmd_state block_id
    mapM_ Log.write logs
    (msgs, logs) <- timed_perform cmd_state ("perform " ++ fname) ui_state
        events
    mapM_ Log.write logs
    return msgs

add_library :: Derive.Library -> Cmd.State -> Cmd.State
add_library lib state = state
    { Cmd.state_ky_cache = Just $ Cmd.KyCache (Right lib) mempty }

timed_perform :: Cmd.State -> FilePath -> State.State -> Cmd.Events
    -> IO ([Midi.WriteMessage], [Log.Msg])
timed_perform cmd_state msg state events =
    Test.print_timer msg (timer_msg (length . fst)) $ do
        let (msgs, logs) = perform cmd_state state events
        Test.force (msgs, logs)
        return (msgs, logs)

timed_derive :: FilePath -> State.State -> Cmd.State -> BlockId
    -> IO (Cmd.Events, [Log.Msg])
timed_derive name ui_state cmd_state block_id = do
    let (perf, logs) = Performance.derive ui_state cmd_state block_id
    Test.print_timer name (timer_msg Vector.length) $ do
        () <- return $ Msg.force_performance perf
        return $! Cmd.perf_events perf
    let warns = filter ((>=Log.Warn) . Log.msg_priority) (Cmd.perf_logs perf)
    return (Cmd.perf_events perf, warns ++ logs)

-- | This is like 'timed_derive', except that it does more work itself
-- rather than calling Performance.derive.  This can be more convenient to
-- look at derivation results.
timed_derive2 :: FilePath -> State.State -> Cmd.State -> BlockId
    -> IO (Cmd.Events, [Log.Msg])
timed_derive2 name ui_state cmd_state block_id =
    case derive_block ui_state cmd_state block_id of
        Left err -> return (mempty, [Log.msg Log.Warn Nothing err])
        Right (result, cmd_logs) -> do
            let (events, derive_logs) = first Vector.fromList $
                    Stream.partition $ Derive.r_events result
                msg = "derive " <> name <> " " <> prettys block_id
            events <- Test.print_timer msg (timer_msg Vector.length)
                (return $! events)
            return (events, cmd_logs ++ filter (not . boring) derive_logs)
    where
    boring = Cache.is_cache_log
    derive_block :: State.State -> Cmd.State -> BlockId
        -> Either Text (Derive.Result, [Log.Msg])
    derive_block ui_state cmd_state block_id =
        run_cmd ui_state cmd_state $ PlayUtil.uncached_derive block_id

timed_lilypond :: FilePath -> State.State -> Cmd.State -> BlockId
    -> IO (Either Text Text, [Log.Msg])
timed_lilypond name ui_state cmd_state block_id = case result of
    Left err -> return (Left err, [])
    Right (levents, cmd_logs) -> do
        let (events, derive_logs) = Stream.partition levents
        events <- Test.print_timer ("lilypond " <> name) (timer_msg length)
            (return $! events)
        let (result, ly_logs) = Cmd.Lilypond.extract_movements
                config "title" events
        return (Lazy.toStrict <$> result,
            cmd_logs ++ filter (not . boring) derive_logs ++ ly_logs)
    where
    result = run_cmd ui_state cmd_state $
        Derive.r_events <$> Cmd.Lilypond.derive_block block_id
    config = State.config#State.lilypond #$ ui_state
    boring = Cache.is_cache_log

timer_msg :: (a -> Int) -> Double -> Double -> a -> String
timer_msg len cpu_secs secs events =
    Printf.printf "events: %d (%d / cpu, %d / sec)"
        events_len (per cpu_secs) (per secs)
    where
    events_len = len events
    per :: Double -> Int
    per secs = round (fromIntegral events_len / secs)

run_cmd :: State.State -> Cmd.State -> Cmd.CmdId a
    -> Either Text (a, [Log.Msg])
run_cmd ui_state cmd_state cmd = case result of
    Left err -> Left $ pretty err
    Right (val, _, _) -> case val of
        Nothing -> Left "cmd had no result"
        Just val -> Right (val, logs)
    where (_, _, logs, result) = Cmd.run_id ui_state cmd_state cmd

perform :: Cmd.State -> State.State -> Cmd.Events
    -> ([Midi.WriteMessage], [Log.Msg])
perform cmd_state ui_state events =
    extract $ run_cmd ui_state cmd_state $ PlayUtil.perform_events events
    where
    extract (Left err) = ([], [Log.msg Log.Error Nothing err])
    extract (Right (levents, logs)) = (events, logs ++ perf_logs)
        where (events, perf_logs) = LEvent.partition levents

-- | Load a score and its accompanying local definitions library, if it has one.
load_score :: FilePath -> IO (Either Text (State.State, Derive.Library))
load_score fname =
    Test.print_timer ("load " ++ fname) (\_ _ _ -> "") $ Error.runErrorT $ do
        save <- require_right $ Save.infer_save_type fname
        (state, dir) <- case save of
            Cmd.SaveRepo repo -> do
                (state, _, _) <- require_right $ SaveGit.load repo Nothing
                return (state, FilePath.takeDirectory repo)
            Cmd.SaveState fname -> do
                maybe_state <- require_right $ Save.read_state_ fname
                state <- maybe (Error.throwError "file not found") return
                    maybe_state
                return (state, FilePath.takeDirectory fname)
        case State.config#State.ky_file #$ state of
            Nothing -> return (state, mempty)
            Just ky_fname -> do
                app_dir <- liftIO Config.get_app_dir
                let paths = dir : map (Config.make_path app_dir) Config.ky_paths
                (lib, _) <- either Error.throwError return
                    =<< liftIO (PlayUtil.load_ky paths ky_fname)
                return (state, lib)

require_right :: IO (Either Text a) -> Error.ErrorT Text IO a
require_right io = either Error.throwError return =<< liftIO io

-- | Load cmd config, which basically means the inst db.
load_cmd_config :: IO Cmd.Config
load_cmd_config = do
    config <- Local.Config.load_static_config
    cmd_config (StaticConfig.instrument_db config)

cmd_config :: Cmd.InstrumentDb -> IO Cmd.Config
cmd_config inst_db = do
    interface <- StubMidi.interface
    app_dir <- Config.get_app_dir
    return $ Cmd.Config
        { Cmd.state_app_dir = app_dir
        , Cmd.state_midi_interface = interface
        , Cmd.state_ky_paths = map (Config.make_path app_dir) Config.ky_paths
        , Cmd.state_rdev_map = mempty
        , Cmd.state_wdev_map = mempty
        , Cmd.state_instrument_db = inst_db
        , Cmd.state_library = Call.All.library
        , Cmd.state_lookup_scale = Scale.All.lookup_scale
        , Cmd.state_highlight_colors = mempty
        }
