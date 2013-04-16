{-# LANGUAGE ScopedTypeVariables, CPP #-}
-- | Sequencer.
--
-- Dumadak tan wenten alangan.
-- 希望沒有錯誤。
module App.Main where
#include "hsconfig.h"
import qualified Control.Concurrent.MVar as MVar
import qualified Control.Concurrent.STM as STM
import qualified Control.Concurrent.STM.TChan as TChan
import qualified Control.Exception as Exception
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Network
import qualified System.Directory as Directory
import qualified System.Environment
import qualified System.FilePath as FilePath
import System.FilePath ((</>))
import qualified System.IO as IO
import qualified System.Posix as Posix
import qualified System.Process as Process
#ifdef USE_EKG
import qualified Data.ByteString.Char8 as ByteString
import qualified System.Remote.Monitoring
#endif

import Util.Control
import qualified Util.File as File
import qualified Util.Log as Log
import qualified Util.Map as Map
import qualified Util.Pretty as Pretty
import qualified Util.Thread as Thread

import qualified Ui.Ui as Ui
import qualified Midi.Midi as Midi
import qualified Midi.Interface as Interface

-- This is the actual midi implementation.  This is the only module that should
-- depend on the implementation, so switching backends is relatively easy.
#if defined(CORE_MIDI)
import qualified Midi.CoreMidi as MidiDriver
#elif defined(JACK_MIDI)
import qualified Midi.JackMidi as MidiDriver
#else
import qualified Midi.StubMidi as MidiDriver
#endif

import qualified Cmd.GlobalKeymap as GlobalKeymap
import qualified Cmd.Lang as Lang
import qualified Cmd.Responder as Responder

import qualified Derive.Call.All as Call.All
import qualified Derive.Call.Symbols as Call.Symbols
import qualified Derive.Instrument.Symbols as Instrument.Symbols
import qualified Derive.Scale.All as Scale.All
import qualified Derive.Scale.Symbols as Scale.Symbols

import qualified Instrument.Db as Db

import qualified App.Config as Config
import qualified App.LoadConfig as LoadConfig
import qualified App.StaticConfig as StaticConfig

import qualified Local.Config

-- This is only used by the REPL,  but by importing it here I can make
-- sure it, along with REPL-only modules, are compiled and don't have any
-- errors.
import Cmd.Lang.Environ ()


initialize :: (Network.Socket -> Interface.Interface -> IO ()) -> IO ()
initialize app = do
    log_hdl <- rotate_logs
    Log.configure $ const $
        Log.State (Just log_hdl) Log.Debug Log.serialize_msg
    MidiDriver.initialize "seq" want_message $ \interface -> case interface of
        Left err -> error $ "initializing midi: " ++ err
        Right midi_interface -> Network.withSocketsDo $ do
            Config.initialize_repl_port
            socket <- Network.listenOn Config.repl_port
            midi_interface <- Interface.track_interface midi_interface
            app socket midi_interface
    where
    want_message (Midi.RealtimeMessage Midi.ActiveSense) = False
    want_message _ = True

rotate_logs :: IO IO.Handle
rotate_logs = do
    log_dir <- flip Config.make_path Config.log_dir <$> Config.get_app_dir
    let log_fn = log_dir </> "seq.log"
        rotated_fn n = log_dir </> "seq." ++ show n ++ ".gz"
    size <- maybe 0 Posix.fileSize <$> ignore (Posix.getFileStatus log_fn)
    when (size >= max_size) $ do
        forM_ (reverse (zip [1..keep] (drop 1 [1..keep]))) $ \(from, to) ->
            ignore $ Directory.renameFile (rotated_fn from) (rotated_fn to)
        let fn = FilePath.dropExtension (rotated_fn 1)
        ignore $ Directory.renameFile log_fn fn
        Process.waitForProcess =<< Process.runProcess "gzip" [fn]
            Nothing Nothing Nothing Nothing Nothing
        return ()
    IO.openFile log_fn IO.AppendMode
    where
    max_size = 4 * 1024 * 1024
    keep = 4
    ignore = File.ignore_enoent

main :: IO ()
main = initialize $ \repl_socket midi_interface -> do
#ifdef USE_EKG
    System.Remote.Monitoring.forkServer (ByteString.pack "localhost") 8080
#endif
    -- Handy to filter debugging output.
    IO.hSetBuffering IO.stdout IO.LineBuffering
    Log.notice "app starting"
    static_config <- Local.Config.load_static_config
    let loaded_msg = "instrument db loaded, "
            ++ show (Db.size (StaticConfig.instrument_db static_config))
            ++ " instruments loaded"
    Log.notice loaded_msg
    putStrLn loaded_msg

    let _x = _x
    -- satellites are out tonight

    let open_read = StaticConfig.read_devices (StaticConfig.midi static_config)
    rdevs <- Interface.read_devices midi_interface
    mapM_ (Interface.connect_read_device midi_interface) (Set.toList open_read)
    wdevs <- Interface.write_devices midi_interface
    forM_ (map fst wdevs) (Interface.connect_write_device midi_interface)
    print_devs open_read rdevs wdevs

    setup_cmd <- StaticConfig.setup_cmd static_config <$>
        System.Environment.getArgs

    -- TODO Sending midi through the whole responder thing is too laggy for
    -- thru.  So give it a shortcut here, but I'll need to give a way to insert
    -- the thru function.  I'll do some responder optimizations first.
    -- thru_chan <- STM.atomically $
    --          STM.dupTChan (Interface.read_channel midi_interface)
    -- Thread.start_logged "midi thru" $
    --     midi_thru remap_rmsg thru_chan write_midi

    loopback_chan <- STM.newTChanIO
    msg_chan <- STM.newTChanIO
    get_msg <- Responder.create_msg_reader
        (remap_read_message (StaticConfig.rdev_map
            (StaticConfig.midi static_config)))
        (Interface.read_channel midi_interface) repl_socket msg_chan
        loopback_chan

    startup_initialization

    session <- Lang.make_session
    quit_request <- MVar.newMVar ()
    Thread.start_logged "interpreter" $ do
        Lang.interpreter session
        `Exception.finally` Ui.quit_ui_thread quit_request
        -- ctrl-C is killing this thread now.  The interaction between signals
        -- and OS threads managed by the GHC RTS is probably unpredictable.
        -- I gather the recommended way is to start a thread for signal
        -- handling, I'll do that if this causes more trouble.

    Thread.start_logged "responder" $ do
        let loopback msg = STM.atomically (TChan.writeTChan loopback_chan msg)
        Responder.responder static_config get_msg midi_interface
            setup_cmd session loopback
        `Exception.catch` (\(exc :: Exception.SomeException) ->
            Log.error $ "responder thread died from exception: " ++ show exc)
            -- It would be possible to restart the responder, but chances are
            -- good it would just die again.
        `Exception.finally` Ui.quit_ui_thread quit_request
    Ui.event_loop quit_request msg_chan
        `Exception.catch` \(exc :: Exception.SomeException) ->
            Log.error $ "ui died from exception: " ++ show exc

    Interface.abort midi_interface
    mapM_ (Interface.write_message midi_interface)
        [Interface.AllNotesOff 0, Interface.reset_pitch 0]
    Log.notice "app quitting"

-- | Do one-time startup tasks.
startup_initialization :: IO ()
startup_initialization = do
    LoadConfig.symbols $ Call.Symbols.symbols ++ Scale.Symbols.symbols
        ++ Instrument.Symbols.symbols
    LoadConfig.styles Config.styles
    -- Report keymap and call overlaps.
    mapM_ Log.warn GlobalKeymap.cmd_map_errors
    forM_ shadows $ \(name, shadowed) ->
        Log.warn $ name ++ " calls shadowed: " ++ Pretty.pretty shadowed
    unless (null Scale.All.shadowed) $
        Log.warn $ "scales shadowed: " ++ Pretty.pretty Scale.All.shadowed
    where
    shadows = filter (not . null . snd)
        [ ("note", Call.All.shadowed_notes)
        , ("control", Call.All.shadowed_controls)
        , ("pitch", Call.All.shadowed_pitches)
        , ("val", Call.All.shadowed_vals)
        ]

{-
midi_thru remap_rmsg midi_chan write_midi = forever $ do
    rmsg <- fmap remap_rmsg (STM.atomically (STM.readTChan midi_chan))
    let wmsgs = [Midi.WriteMessage dev 0 msg | (dev, msg) <- process_thru rmsg]
    print rmsg
    mapM_ write_midi wmsgs

process_thru :: Midi.ReadMessage -> [(Midi.WriteDevice, Midi.Message)]
process_thru rmsg = [(Midi.WriteDevice "fm8", Midi.rmsg_msg rmsg)]
-}

remap_read_message :: Map.Map Midi.ReadDevice Midi.ReadDevice
    -> Midi.ReadMessage -> Midi.ReadMessage
remap_read_message dev_map rmsg@(Midi.ReadMessage { Midi.rmsg_dev = dev }) =
    rmsg { Midi.rmsg_dev = Map.get dev dev dev_map }

print_devs :: Set.Set Midi.ReadDevice -> [(Midi.ReadDevice, [Midi.ReadDevice])]
    -> [(Midi.WriteDevice, [Midi.WriteDevice])] -> IO ()
print_devs opened_rdevs rdevs wdevs = do
    putStrLn "read devs:"
    forM_ rdevs $ \(rdev, aliases) ->
        let prefix = if opened rdev aliases then "* " else "  "
        in putStrLn $ prefix ++ Pretty.pretty rdev ++ " "
            ++ Pretty.pretty aliases
    putStrLn "write devs:"
    forM_ wdevs $ \(wdev, aliases) ->
        putStrLn $ "* " ++ Pretty.pretty wdev ++ " " ++ Pretty.pretty aliases
    where
    opened rdev aliases = rdev `Set.member` opened_rdevs
        || any (`Set.member` opened_rdevs) aliases
