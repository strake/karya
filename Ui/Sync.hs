{- | Take Updates, which are generated by 'Ui.Diff', and send them to the UI.

    The C++ level and BlockC have no notion of "blocks" which may be shared
    between block views.  The haskell State does have this notion, so it's this
    module's job to distribute an operation on a block to all of the C++ block
    views that are displaying that block.

    So if this module has a bug, two views of one block could get out of sync
    and display different data.  Hopefully that won't happen.

    Implementation of merged tracks:

    They need to be implemented in two places: 1. when a block is updated with
    changed merged tracks, and 2. when a track is updated they should be
    preserved.  It's tricky because unlike normal track events, they are block
    level, not track level, so the same track in different blocks may be merged
    with different events.  I don't actually see a lot of use-case for the same
    track in different blocks, but as long as I have it, it makes sense that it
    can have different merges in different blocks, since it's really
    a display-level effect.

    This is a hassle because case 1 has to go hunt down the event info and case
    2 has to go hunt down the per-block info, but such is life.
-}
module Ui.Sync (
    sync
    , set_track_signals
    , set_play_position, clear_play_position
) where
import Control.Monad
import qualified Control.Monad.Trans as Trans
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Text as Text

import Util.Control
import qualified Util.Log as Log
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq

import Ui
import qualified Ui.Block as Block
import qualified Ui.BlockC as BlockC
import qualified Ui.Events as Events
import qualified Ui.State as State
import qualified Ui.Track as Track
import qualified Ui.Types as Types
import qualified Ui.Ui as Ui
import qualified Ui.Update as Update

import qualified App.Config as Config


-- | Sync with the ui by applying the given updates to it.
--
-- TrackSignals are passed separately instead of going through diff because
-- they're special: they exist in Cmd.State and not in Ui.State.  It's rather
-- unpleasant, but as long as it's only TrackSignals then I can deal with it.
sync :: Track.TrackSignals -> State.State -> [Update.DisplayUpdate]
    -> IO (Maybe State.StateError)
sync track_signals state updates = do
    -- TODO: TrackUpdates can overlap.  Merge them together here.
    -- Technically I can also cancel out all TrackUpdates that only apply to
    -- newly created views, but this optimization is probably not worth it.
    result <- State.run state $ do_updates track_signals (Update.sort updates)
    -- Log.timer $ "synced updates: " ++ show (length updates)
    return $ case result of
        Left err -> Just err
        -- I reuse State.StateT for convenience, but run_update should
        -- not modify the State and hence shouldn't produce any updates.
        -- TODO Try to split StateT into ReadStateT and ReadWriteStateT to
        -- express this in the type?
        Right _ -> Nothing

do_updates :: Track.TrackSignals -> [Update.DisplayUpdate]
    -> State.StateT IO ()
do_updates track_signals updates = do
    actions <- mapM (run_update track_signals) updates
    -- Trans.liftIO $ putStrLn ("run updates: " ++ show updates)
    Trans.liftIO (Ui.send_action (sequence_ actions))

set_track_signals :: State.State -> Track.TrackSignals -> IO ()
set_track_signals state track_signals =
    case State.eval state rendering_tracks of
        Left err ->
            -- This could happen if track_signals had a stale track_id.  That
            -- could happen if I deleted a track before the deriver came back
            -- with its signal.
            -- TODO but I should just filter out the bad track_id in that case
            Log.warn $ "getting tracknums of track_signals: " ++ show err
        Right tracks -> Ui.send_action $ forM_ tracks set_tsig
    where
    set_tsig (view_id, track_id, tracknum) =
        case Map.lookup track_id track_signals of
            Just (Right tsig) -> BlockC.set_track_signal view_id tracknum tsig
            Just (Left logs) -> mapM_ Log.write $ prefix view_id tracknum logs
            Nothing -> return ()
    prefix view_id tracknum = Log.add_prefix $ Text.pack $
        "getting track signal for " ++ Pretty.pretty (view_id, tracknum)

    rendering_tracks :: State.StateId [(ViewId, TrackId, TrackNum)]
    rendering_tracks = do
        view_ids <- Map.keys <$> State.gets State.state_views
        blocks <- mapM (State.block_of) view_ids
        btracks <- mapM get_tracks blocks
        return $ do
            (view_id, tracks) <- zip view_ids btracks
            ((tracknum, track_id, flags), track) <- tracks
            guard (wants_tsig flags track)
            return (view_id, track_id, tracknum)
    get_tracks block = zip triples <$> mapM State.get_track track_ids
        where
        track_ids = [tid | (_, tid, _) <- triples]
        triples = [(tracknum, tid, Block.track_flags track) |
            (tracknum,
                track@(Block.Track { Block.tracklike_id = Block.TId tid _ }))
            <- zip [0..] (Block.block_tracks block)]

-- | The play position selection bypasses all the usual State -> Diff -> Sync
-- stuff for a direct write to the UI.
--
-- This is because it happens asynchronously and would be noisy and inefficient
-- to work into the responder loop, and isn't part of the usual state that
-- should be saved anyway.
set_play_position :: [(ViewId, [(TrackNum, ScoreTime)])] -> IO ()
set_play_position block_sels = Ui.send_action $ sequence_
    [ BlockC.set_track_selection False view_id
        Config.play_position_selnum tracknum (Just (sel_at pos))
    | (view_id, track_pos) <- block_sels, (tracknum, pos) <- track_pos
    ]
    where
    sel_at pos = BlockC.CSelection Config.play_selection_color
        (Types.selection 0 pos 0 pos)
        -- The 0s are dummy values since set_track_selection ignores them.

clear_play_position :: ViewId -> IO ()
clear_play_position view_id = Ui.send_action $
    BlockC.set_selection False view_id Config.play_position_selnum Nothing


-- * run_update

-- There's a fair amount of copy and paste in here, since CreateView subsumes
-- the functions of InsertTrack and many others.  For example, the merged
-- events of a given track are calculated in 4 separate places.  It's nasty
-- error-prone imperative code.  I'd like to factor it better but I don't know
-- how.
--
-- It's also a little confusing in that this function runs in StateT, but
-- returns an IO action to be run in the UI thread, so there are two monads
-- here.

-- | Generate an IO action that applies the update to the UI.
--
-- CreateView Updates will modify the State to add the ViewPtr.
--
-- This has to be the longest haskell function ever.
run_update :: Track.TrackSignals -> Update.DisplayUpdate
    -> State.StateT IO (IO ())
run_update track_signals (Update.ViewUpdate view_id (Update.CreateView _)) = do
    view <- State.get_view view_id
    block <- State.get_block (Block.view_block view)

    let dtracks = map Block.display_track (Block.block_tracks block)
        btracks = Block.block_tracks block
        tlike_ids = map Block.tracklike_id btracks
    -- It's important to get the tracklikes from the dtracks, not the
    -- tlike_ids.  That's because the dtracks will have already turned
    -- Collapsed tracks into Dividers.
    tracklikes <- mapM (State.get_tracklike . Block.dtracklike_id) dtracks
    titles <- mapM track_title (Block.block_tracklike_ids block)

    let sels = Block.view_selections view
    csels <- mapM (\(selnum, sel) -> to_csel view_id selnum (Just sel))
        (Map.assocs sels)
    ustate <- State.get
    -- I manually sync the new empty view with its state.  It might reduce
    -- repetition to let Diff.diff do that by diffing against a state with an
    -- empty view, but this way seems less complicated if more error-prone.
    -- Sync: title, tracks, selection, skeleton
    return $ do
        let title = block_window_title view_id (Block.view_block view)
        BlockC.create_view view_id title (Block.view_rect view)
            (Block.view_config view) (Block.block_config block)
        mapM_ (create_track ustate)
            (List.zip6 [0..] dtracks btracks tlike_ids tracklikes titles)
        unless (null (Block.block_title block)) $
            BlockC.set_title view_id (Block.block_title block)
        BlockC.set_skeleton view_id (Block.block_skeleton block)
        forM_ (zip (Map.keys sels) csels) $ \(selnum, csel) ->
            BlockC.set_selection True view_id selnum csel
        BlockC.set_status view_id (Block.show_status (Block.view_status view))
        BlockC.set_zoom view_id (Block.view_zoom view)
        BlockC.set_track_scroll view_id (Block.view_track_scroll view)
    where
    -- It's kind of dumb how scattered the track info is.  But this is about
    -- the only place where it's needed all together.
    create_track ustate (tracknum, dtrack, btrack, tlike_id, tlike, title) = do
        let merged = events_of_track_ids ustate
                (Block.dtrack_merged dtrack)
        BlockC.insert_track view_id tracknum tlike merged
            (Block.dtrack_width dtrack)
        unless (null title) $
            BlockC.set_track_title view_id tracknum title
        BlockC.set_display_track view_id tracknum dtrack
        case (tlike, tlike_id) of
            (Block.T t _, Block.TId tid _) ->
                case Map.lookup tid track_signals of
                    Just (Right tsig)
                        | wants_tsig (Block.track_flags btrack) t ->
                            BlockC.set_track_signal view_id tracknum tsig
                    _ -> return ()
            _ -> return ()

run_update _ (Update.ViewUpdate view_id update) = case update of
    -- The previous equation matches CreateView, but ghc warning doesn't
    -- figure that out.
    Update.CreateView {} -> error "run_update: notreached"
    Update.DestroyView -> return $ BlockC.destroy_view view_id
    Update.ViewSize rect -> return $ BlockC.set_size view_id rect
    Update.ViewConfig config -> return $ BlockC.set_view_config view_id config
    Update.Status status ->
        return $ BlockC.set_status view_id (Block.show_status status)
    Update.TrackScroll offset ->
        return $ BlockC.set_track_scroll view_id offset
    Update.Zoom zoom -> return $ BlockC.set_zoom view_id zoom
    Update.Selection selnum maybe_sel -> do
        csel <- to_csel view_id selnum maybe_sel
        return $ BlockC.set_selection True view_id selnum csel
    Update.BringToFront -> return $ BlockC.bring_to_front view_id

-- Block ops apply to every view with that block.
run_update track_signals (Update.BlockUpdate block_id update) = do
    view_ids <- fmap Map.keys (State.get_views_of block_id)
    case update of
        Update.BlockTitle title -> return $
            mapM_ (flip BlockC.set_title title) view_ids
        Update.BlockConfig config -> return $
            mapM_ (flip BlockC.set_model_config config) view_ids
        Update.BlockSkeleton skel -> return $
            mapM_ (flip BlockC.set_skeleton skel) view_ids
        Update.RemoveTrack tracknum -> return $
            mapM_ (flip BlockC.remove_track tracknum) view_ids
        Update.InsertTrack tracknum dtrack ->
            create_track view_ids tracknum dtrack
        Update.BlockTrack tracknum dtrack  -> do
            tracklike <- State.get_tracklike (Block.dtracklike_id dtrack)
            ustate <- State.get
            return $ forM_ view_ids $ \view_id -> do
                BlockC.set_display_track view_id tracknum dtrack
                let merged = events_of_track_ids ustate
                        (Block.dtrack_merged dtrack)
                -- This is unnecessary if I just collapsed the track, but
                -- no big deal.
                BlockC.update_entire_track False view_id tracknum tracklike
                    merged
    where
    create_track view_ids tracknum dtrack = do
        let tlike_id = Block.dtracklike_id dtrack
        ctrack <- State.get_tracklike tlike_id
        ustate <- State.get

        -- I need to get this for wants_tsig.
        mb_btrack <- fmap (\b -> Seq.at (Block.block_tracks b) tracknum)
            (State.get_block block_id)
        flags <- case mb_btrack of
            Nothing -> do
                Trans.liftIO $ Log.warn $
                    "InsertTrack with tracknum that's not in the block's "
                    ++ "tracks: " ++ show update
                return []
            Just btrack -> return (Block.track_flags btrack)
        return $ forM_ view_ids $ \view_id -> do
            let merged = events_of_track_ids ustate
                    (Block.dtrack_merged dtrack)
            BlockC.insert_track view_id tracknum ctrack merged
                (Block.dtrack_width dtrack)
            case (tlike_id, ctrack) of
                -- Configure new track.  This is analogous to the initial
                -- config in CreateView.
                (Block.TId tid _, Block.T t _) -> do
                    unless (null (Track.track_title t)) $
                        BlockC.set_track_title view_id tracknum
                            (Track.track_title t)
                    BlockC.set_display_track view_id tracknum dtrack
                    case Map.lookup tid track_signals of
                        Just (Right tsig) | wants_tsig flags t ->
                            BlockC.set_track_signal view_id tracknum tsig
                        _ -> return ()
                _ -> return ()

run_update _ (Update.TrackUpdate track_id update) = do
    blocks <- State.blocks_with_track track_id
    let tinfo = [(block_id, tracknum, tid)
            | (block_id, tracks) <- blocks, (tracknum, tid) <- tracks]
    -- lookup DisplayTrack and pair with the tracks
    fmap sequence_ $ forM tinfo $ \(block_id, tracknum, tracklike_id) -> do
        view_ids <- fmap Map.keys (State.get_views_of block_id)
        tracklike <- State.get_tracklike tracklike_id

        ustate <- State.get
        block <- State.get_block block_id
        let merged = case Seq.at (Block.block_tracks block) tracknum of
                Just track ->
                    events_of_track_ids ustate (Block.track_merged track)
                Nothing -> []
        fmap sequence_ $ forM view_ids $ \view_id -> case update of
            Update.TrackEvents low high _events ->
                return $ BlockC.update_track False view_id tracknum tracklike
                    merged low high
            Update.TrackAllEvents _events ->
                return $ BlockC.update_entire_track False view_id tracknum
                    tracklike merged
            Update.TrackTitle title ->
                return $ BlockC.set_track_title view_id tracknum title
            Update.TrackBg _color ->
                -- update_track also updates the bg color
                return $ BlockC.update_track False view_id tracknum tracklike
                    merged 0 0
            Update.TrackRender _render ->
                return $ BlockC.update_entire_track False view_id tracknum
                    tracklike merged

run_update _ (Update.RulerUpdate ruler_id _ruler) = do
    blocks <- State.blocks_with_ruler ruler_id
    let tinfo = [(block_id, tracknum, tid)
            | (block_id, tracks) <- blocks, (tracknum, tid) <- tracks]
    fmap sequence_ $ forM tinfo $ \(block_id, tracknum, tracklike_id) -> do
        view_ids <- fmap Map.keys (State.get_views_of block_id)
        tracklike <- State.get_tracklike tracklike_id
        -- A ruler track doesn't have merged events so don't bother to look for
        -- them.
        fmap sequence_ $ forM view_ids $ \view_id -> return $
            BlockC.update_entire_track True view_id tracknum tracklike []

run_update _ (Update.StateUpdate ()) = return (return ())

-- | Don't send a track signal to a track unless it actually wants to draw it.
wants_tsig :: [Block.TrackFlag] -> Track.Track -> Bool
wants_tsig flags track =
    Track.render_style (Track.track_render track) /= Track.NoRender
    && Block.Collapse `notElem` flags

track_title (Block.TId track_id _) =
    fmap Track.track_title (State.get_track track_id)
track_title _ = return ""

-- | Generate the title for block windows.
block_window_title :: ViewId -> BlockId -> String
block_window_title view_id block_id = show block_id ++ " -- " ++ show view_id

events_of_track_ids :: State.State -> [TrackId] -> [Events.Events]
events_of_track_ids ustate track_ids = Maybe.mapMaybe events_of track_ids
    where
    events_of track_id = fmap Track.track_events (Map.lookup track_id tracks)
    tracks = State.state_tracks ustate

to_csel :: ViewId -> Types.SelNum -> Maybe Types.Selection
    -> State.StateT IO (Maybe BlockC.CSelection)
to_csel view_id selnum maybe_sel = do
    view <- State.get_view view_id
    block <- State.get_block (Block.view_block view)
    let color = Seq.at_err "selection colors"
            (Block.config_selection_colors (Block.block_config block))
            selnum
    return $ fmap (BlockC.CSelection color) maybe_sel
