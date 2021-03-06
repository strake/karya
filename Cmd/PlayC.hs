-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{- | The FFI-using part of "Cmd.Play".  It uses the FFI because the play
    monitor wants to directly call to the UI to update the playback indicator,
    which is much more efficient than going through the whole "Ui.Diff" thing.

    But that means "Cmd.Play" would import FFI-using modules, which causes
    a problem for ghci, and, since I want the Cmd.Play functions to be
    available there, for the REPL as well.  So I engage in a hack: the play cmd
    returns a special 'Cmd.PlayMidi' value which contains the arguments for the
    play monitor thread.  The responder treats it as a Done but will call
    'play' with the given args.

    Actually since I have *Stub modules now I think this hack is no longer
    needed.  But I'll leave it in place for now since it doesn't seem to
    be hurting anything and it's nice to divide play into low and high level.
-}
module Cmd.PlayC (cmd_play_msg, play) where
import qualified Control.Concurrent.MVar as MVar
import qualified Control.Exception as Exception
import qualified Data.Map.Strict as Map
import qualified Data.Maybe as Maybe
import qualified Data.Set as Set
import qualified Data.Vector as Vector

import qualified Util.Log as Log
import qualified Util.Num as Num
import qualified Util.Seq as Seq
import qualified Util.Thread as Thread

import qualified Ui.Block as Block
import qualified Ui.Color as Color
import qualified Ui.Fltk as Fltk
import qualified Ui.Sync as Sync
import qualified Ui.Track as Track
import qualified Ui.Ui as Ui

import qualified Cmd.Cmd as Cmd
import qualified Cmd.Msg as Msg
import qualified Cmd.Perf as Perf

import qualified Derive.Score as Score
import qualified Derive.Stack as Stack
import qualified Perform.Midi.Play as Midi.Play
import qualified Perform.Transport as Transport
import qualified App.Config as Config
import Global
import Types


-- * cmd_play_msg

-- | Respond to msgs about derivation and playing status.
cmd_play_msg :: Fltk.Channel -> Msg.Msg -> Cmd.CmdT IO Cmd.Status
cmd_play_msg ui_chan msg = do
    case msg of
        Msg.Transport status -> transport_msg status
        Msg.DeriveStatus block_id status -> derive_status_msg block_id status
        _ -> Cmd.abort
    return Cmd.Done
    where
    transport_msg status = case status of
        Transport.Playing -> set_all_play_boxes Config.play_color
        -- Either the performer has declared itself stopped, or the play
        -- monitor has declared it stopped.  In any case, I don't need
        -- a transport to tell it what to do anymore.
        Transport.Stopped -> do
            Cmd.modify_play_state $ \st ->
                st { Cmd.state_play_control = Nothing }
            -- This will cover up derive status info, but that should be ok.
            -- And play normally only comes after derive is completed.
            set_all_play_boxes Config.box_color
        Transport.Died err_msg -> Log.warn $ "player died: " <> txt err_msg
    derive_status_msg block_id status = do
        whenJust (derive_status_color status) (Ui.set_play_box block_id)
        -- When I get word that a performance is complete, I promote it from
        -- state_current_performance to state_performance.  Previously I used
        -- the performance in the DeriveComplete, but Play may have flipped
        -- the 'Cmd.perf_logs_written' bit.  More subtle, I don't want to
        -- have different versions of the same Performance kicking around
        -- because it has lazy fields, and a less-forced version could keep
        -- data alive.
        case status of
            Msg.DeriveComplete {} -> do
                current <- Cmd.gets $
                    Cmd.state_current_performance . Cmd.state_play
                whenJust (Map.lookup block_id current) $ \perf -> do
                    Cmd.modify_play_state $ \st -> st
                        { Cmd.state_performance = Map.insert block_id
                            perf (Cmd.state_performance st)
                        }
                    liftIO $ update_track_signals ui_chan block_id
                        (Cmd.perf_ui_state perf) (Cmd.perf_track_signals perf)
                    update_highlights ui_chan block_id (Cmd.perf_events perf)
            _ -> return ()
    derive_status_color status = case status of
        Msg.OutOfDate {} -> Just $ Color.brightness 1.5 Config.busy_color
        Msg.Deriving {} -> Just Config.busy_color
        Msg.DeriveComplete _ Msg.ImStarted ->
            Just $ Color.brightness 0.5 Config.busy_color
        Msg.DeriveComplete _ Msg.ImUnnecessary -> Just Config.box_color
        Msg.ImComplete -> Just Config.box_color

set_all_play_boxes :: Ui.M m => Color.Color -> m ()
set_all_play_boxes color =
    mapM_ (flip Ui.set_play_box color) =<< Ui.all_block_ids

type Range = (TrackTime, TrackTime)

-- ** track signals

-- | This takes the Ui.State from 'Cmd.perf_ui_state' because the current
-- Ui.State may have changes which haven't yet been synced to the UI.
update_track_signals :: Fltk.Channel -> BlockId -> Ui.State
    -> Track.TrackSignals -> IO ()
update_track_signals ui_chan block_id state tsigs =
    case rendering_tracks block_id state of
        -- This means a bad BlockId or bug in rendering_tracks.
        Left err -> Log.error $ pretty err
        Right tracks -> Sync.set_track_signals ui_chan $
            [ (view_id, tracknum, if wants_tsig
                then Map.findWithDefault empty (block_id, track_id) tsigs
                else empty)
            | (view_id, track_id, tracknum, wants_tsig) <- tracks
            ]
    where
    -- If there's no recorded signal, I send an empty one, to make sure that if
    -- there used to be one I will clear it out.  This is because "removed an
    -- existing track signal" and "never had a track signal" look the same
    -- from here, and always sending an empty seems less error-prone than
    -- trying to figure out the distinction.
    empty = Track.empty_track_signal

-- | Get the tracks of this block and whether they want to render a signal.
rendering_tracks :: BlockId -> Ui.State
    -> Either Ui.Error [(ViewId, TrackId, TrackNum, Bool)]
rendering_tracks block_id state = Ui.eval state $ do
    view_ids <- Map.keys <$> Ui.views_of block_id
    blocks <- mapM Ui.block_of view_ids
    btracks <- mapM get_tracks blocks
    return $ do
        (view_id, tracks) <- zip view_ids btracks
        ((tracknum, track_id, flags), track) <- tracks
        -- I don't want to send even an empty signal to these.
        guard $ Block.Collapse `Set.notMember` flags
        return (view_id, track_id, tracknum,
            Block.track_wants_signal flags track)
    where
    get_tracks block = zip triples <$> mapM Ui.get_track track_ids
        where
        track_ids = [tid | (_, tid, _) <- triples]
        triples =
            [ (tracknum, tid, Block.track_flags track)
            | (tracknum,
                track@(Block.Track { Block.tracklike_id = Block.TId tid _ }))
                <- zip [0..] (Block.block_tracks block)
            ]

-- ** highlights

-- | Get highlights from the events, clear old highlights, and set the new ones.
update_highlights :: Fltk.Channel -> BlockId -> Vector.Vector Score.Event
    -> Cmd.CmdT IO ()
update_highlights ui_chan block_id events = do
    sels <- get_event_highlights block_id events
    view_ids <- Map.keysSet <$> Ui.views_of block_id
    let used_view_ids = Set.fromList [view_id | ((view_id, _), _) <- sels]
    liftIO $ do
        Sync.clear_highlights ui_chan $
            Set.toList $ view_ids `Set.difference` used_view_ids
        Sync.set_highlights ui_chan sels

-- | Get highlight selections from the events.
get_event_highlights :: Cmd.M m => BlockId
    -- ^ only get highlights for events on this block
    -> Vector.Vector Score.Event
    -> m [((ViewId, TrackNum), (Range, Color.Color))]
get_event_highlights block_id events = do
    colors <- Cmd.gets $ Cmd.config_highlight_colors . Cmd.state_config
    resolve_tracks $ event_highlights block_id colors events

resolve_tracks :: Ui.M m => [((BlockId, TrackId), a)]
    -> m [((ViewId, TrackNum), a)]
resolve_tracks = concatMapM resolve
    where
    resolve ((block_id, track_id), val) = do
        tracknum <- Ui.get_tracknum_of block_id track_id
        view_ids <- Map.keys <$> Ui.views_of block_id
        return [((view_id, tracknum), val) | view_id <- view_ids]

event_highlights :: BlockId -> Map Color.Highlight Color.Color
    -> Vector.Vector Score.Event
    -> [((BlockId, TrackId), (Range, Color.Color))]
event_highlights derived_block_id colors
    | Map.null colors = const []
    | otherwise = Seq.unique_on key . Vector.foldr collect []
    where
    key (track, (range, _)) = (track, range)
    collect event accum
        | highlight /= Color.NoHighlight,
                Just (block_id, track_id, range) <- maybe_pos,
                block_id == derived_block_id,
                Just color <- Map.lookup highlight colors =
            ((block_id, track_id), (range, color)) : accum
        | otherwise = accum
        where
        highlight = Score.event_highlight event
        maybe_pos = Stack.block_track_region_of $ Score.event_stack event

-- * play

-- | This actually kicks off a MIDI play thread, and if an inverse tempo
-- function is given, a play monitor thread.
play :: Fltk.Channel -> Ui.State -> Transport.Info -> Cmd.PlayMidiArgs
    -> IO Transport.PlayControl
play ui_chan ui_state transport_info
        (Cmd.PlayMidiArgs mmc name msgs maybe_inv_tempo repeat_at im_end) = do
    (play_ctl, monitor_ctl) <-
        Midi.Play.play transport_info mmc name msgs repeat_at
    -- Pass the current state in the MVar.  ResponderSync will keep it up
    -- to date afterwards, but only if blocks are added or removed.
    MVar.modifyMVar_ (Transport.info_state transport_info) $
        const (return ui_state)
    liftIO $ void $ Thread.start $ case maybe_inv_tempo of
        Just inv_tempo -> do
            state <- monitor_state ui_chan transport_info play_ctl monitor_ctl
                inv_tempo repeat_at im_end
            play_monitor_thread (Transport.info_send_status transport_info)
                state
        Nothing -> passive_play_monitor_thread
            (Transport.info_send_status transport_info) monitor_ctl
    return play_ctl

-- | Just coordinate Playing and Stopped, don't update a play position.
passive_play_monitor_thread :: (Transport.Status -> IO ())
    -> Transport.PlayMonitorControl -> IO ()
passive_play_monitor_thread send monitor_ctl =
    Exception.bracket_ (send Transport.Playing) (send Transport.Stopped) $
        Transport.wait_player_stopped monitor_ctl

-- | Run along the InverseTempoMap and update the play position selection.
-- Note that this goes directly to the UI through Sync, bypassing the usual
-- state diff folderol.
play_monitor_thread :: (Transport.Status -> IO ()) -> MonitorState -> IO ()
play_monitor_thread send_status state = do
    ui_state <- MVar.readMVar (monitor_ui_state state)
    Sync.clear_play_position (monitor_ui_channel state) $
        Map.keys $ Ui.state_views ui_state
    Exception.bracket_
        (send_status Transport.Playing) (send_status Transport.Stopped)
        (monitor_loop state)

monitor_state :: Fltk.Channel -> Transport.Info
    -> Transport.PlayControl
    -> Transport.PlayMonitorControl
    -> Transport.InverseTempoFunction
    -> Maybe RealTime -> Maybe RealTime
    -> IO MonitorState
monitor_state ui_chan transport_info play_ctl monitor_ctl inv_tempo_func
        repeat_at im_end = do
    let get_now = Transport.info_get_current_time transport_info
    -- This won't be exactly the same as the renderer's ts offset, but
    -- it's probably close enough.
    offset <- get_now
    return $ MonitorState
        { monitor_ctl = monitor_ctl
        , monitor_play_ctl = play_ctl
        , monitor_offset = offset
        , monitor_get_now = get_now
        , monitor_inv_tempo_func = inv_tempo_func
        , monitor_active_sels = Set.empty
        , monitor_ui_state = Transport.info_state transport_info
        , monitor_repeat_at = repeat_at
        , monitor_ui_channel = ui_chan
        , monitor_im_end = im_end
        }

data MonitorState = MonitorState {
    monitor_ctl :: !Transport.PlayMonitorControl
    , monitor_play_ctl :: !Transport.PlayControl
    -- | When the monitor thread started.
    , monitor_offset :: !RealTime
    , monitor_get_now :: !(IO RealTime)
    , monitor_inv_tempo_func :: !Transport.InverseTempoFunction
    , monitor_active_sels :: !(Set (ViewId, [TrackNum]))
    , monitor_ui_state :: !(MVar.MVar Ui.State)
    , monitor_repeat_at :: !(Maybe RealTime)
    , monitor_ui_channel :: !Fltk.Channel
    , monitor_im_end :: !(Maybe RealTime)
    }

monitor_loop :: MonitorState -> IO ()
monitor_loop state = do
    now <- maybe id (flip Num.fmod) (monitor_repeat_at state)
        . subtract (monitor_offset state) <$> monitor_get_now state
    let fail err = Log.error ("state error in play monitor: " <> showt err)
            >> return []
    ui_state <- MVar.readMVar (monitor_ui_state state)
    let block_pos = monitor_inv_tempo_func state now
    play_pos <- fmap extend_to_track_0 $ either fail return $
        Ui.eval ui_state $ Perf.block_pos_to_play_pos block_pos
    Sync.set_play_position (monitor_ui_channel state) play_pos

    let active_sels = Set.fromList
            [(view_id, map fst num_pos) | (view_id, num_pos) <- play_pos]
    Sync.clear_play_position (monitor_ui_channel state) $ map fst $ Set.toList $
        Set.difference (monitor_active_sels state) active_sels
    state <- return $ state { monitor_active_sels = active_sels }

    midi_stopped <- Transport.poll_player_stopped 0 (monitor_ctl state)
    -- If repeat_at is on, then the MIDI player will never stop on its own,
    -- even if I run out of tempo map (which happens if the repeat point is at
    -- or past the end of the score).  When the monitor thread stops, it sends
    -- Stopped on the transport, which clears out the player ctl which will
    -- make the player unstoppable, if it's still going.
    let out_of_score = null block_pos
            && Maybe.isNothing (monitor_repeat_at state)
    -- Since im playback is done by the VST, I don't directly control it as I
    -- do with the MIDI player.  Instead, infer that it's complete if either
    -- we've gone past its last note, or the user requested a stop.
    im_stopped <- orM
        [ return $ maybe True (now>) (monitor_im_end state)
        , Transport.poll_stop_player 0 (monitor_play_ctl state)
        ]
    if (midi_stopped && im_stopped) || out_of_score
        then do
            Sync.clear_play_position (monitor_ui_channel state) $ map fst $
                Set.toList (monitor_active_sels state)
            -- Don't send a Transport.Stopped until the MIDI thread is done.
            unless midi_stopped $
                Transport.wait_player_stopped (monitor_ctl state)
        else Thread.delay 0.05 >> monitor_loop state

-- | If there's a playback on track 1 but not on track 0, then track 0 is
-- probably a ruler.  If I put a playback there too, then the playback position
-- will be more obvious on a narrow block.
extend_to_track_0 :: [(ViewId, [(TrackNum, ScoreTime)])]
    -> [(ViewId, [(TrackNum, ScoreTime)])]
extend_to_track_0 = map (second extend)
    where
    extend ((tracknum, t) : tracks)
        | tracknum == 1 = (0, t) : (1, t) : tracks
    extend tracks = tracks
