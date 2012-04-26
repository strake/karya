{- | Implement a clipboard, and copy and paste from a selection.

    Who knew copy and paste was so complicated?  Copying is complicated because
    the structure isn't flat, i.e. a block has references to tracks and rulers.
    Pasting is complicated because the clipboard events have to be shifted and
    clipped according to the destination selection.

    Also, the tracks are typed in that it's not appropriate to paste control
    events into a note track.  However, I'm going to ignore that and assume the
    user won't paste them if he didn't mean it.

    Instead of having a special case clipboard, the clipboard is implemented as
    a set of normal blocks and tracks (rulers are not copied), in a clipboard
    namespace.  That way, you can have multiple clipboards by copying them to
    different clipboard namespaces, edit clipboards in place, and the paste
    code is the same as the code that merges another project from disk.

    Further ideas:

    - use two selections and a "swap" command

    - mouse chording for copy paste

    - different mouse buttons are hard to do on the mac, so use standard for now

    - merge with function... I think I can just do it at the REPL

    More complicated pastes should be implemented as derivers, which are more
    flexible than editing operations.  However, there could be a "derive in
    place" cmd to flatten deriver structure.
-}
module Cmd.Clip where
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe

import Util.Control
import qualified Util.Seq as Seq
import qualified Ui.Block as Block
import qualified Ui.Event as Event
import qualified Ui.Events as Events
import qualified Ui.Id as Id
import qualified Ui.State as State
import qualified Ui.Track as Track
import qualified Ui.Transform as Transform
import qualified Ui.Types as Types

import qualified Cmd.Cmd as Cmd
import qualified Cmd.Create as Create
import qualified Cmd.Edit as Edit
import qualified Cmd.ModifyEvents as ModifyEvents
import qualified Cmd.Selection as Selection

import qualified App.Config as Config
import Types


-- * clipboard ops

-- | Replace the clipboard with the given state.
--
-- TODO If there is an open view on a given block, maybe it can be reopened.
-- Or maybe there can be a setting to automatically open a view on a copied
-- block.
state_to_clip :: (Cmd.M m) => State.State -> m ()
state_to_clip state = state_to_namespace state =<< get_clip_namespace

clear_clip :: (Cmd.M m) => m ()
clear_clip = destroy_namespace =<< get_clip_namespace

-- * copy

-- | Like 'cmd_copy_selection', but shift the following events back by the
-- selection duration.
cmd_cut_selection :: (Cmd.M m) => m ()
cmd_cut_selection = do
    cmd_copy_selection
    Edit.cmd_clear_selected

-- | Copy events under the current selection into the buffer.
cmd_copy_selection :: (Cmd.M m) => m ()
cmd_copy_selection = do
    selected <- get_selection =<< copy_selection Config.insert_selnum
    clip_block_id <- get_clip_block_id
    state <- State.require_right "selected_to_state" $
        selected_to_state clip_block_id selected
    state_to_clip state

copy_selection :: (Cmd.M m) => Types.SelNum -> m Selection.SelectedTracks
copy_selection selnum = do
    sel@(_, _, _, start, end) <- Selection.tracks_selnum selnum
    when (start == end) Cmd.abort
    return sel

-- | (track_title, events) pairs for each copied track within the copied
-- selection.
type Selected = [(String, Events.Events)]

selected_to_state :: BlockId -> Selected -> Either State.StateError State.State
selected_to_state block_id selected = State.exec State.empty $ do
    State.set_namespace $ Id.id_namespace $ Id.unpack_id block_id
    State.create_block (Id.unpack_id block_id) ""
        [Block.track (Block.RId State.no_ruler) 0]
    forM_ (zip [0..] selected) $ \(tracknum, (title, events)) -> do
        Create.track_events block_id State.no_ruler tracknum
            Config.track_width (Track.track title events)

get_selection :: (Cmd.M m) => Selection.SelectedTracks -> m Selected
get_selection (block_id, tracknums, _, start, end) = do
    tracks <- mapM State.get_track =<< Maybe.catMaybes <$>
        mapM (State.event_track_at block_id) tracknums
    return $ map extract tracks
    where
    extract track = (Track.track_title track,
        select_events start end (Track.track_events track))

select_events :: ScoreTime -> ScoreTime -> Events.Events -> Events.Events
select_events start end = Events.map_sorted (\(pos, evt) -> (pos - start, evt))
    . Events.in_range start end

-- * paste

-- $paste Insert events from the clipboard to the selection. If the selection
-- is a point it's the same as if it extended to the end of the block.

-- | The normal variety of paste that replaces the destination data.
cmd_paste_overwrite :: (Cmd.M m) => m ()
cmd_paste_overwrite = do
    (start, end, track_events) <- paste_info
    forM_ track_events $ \(track_id, events) -> do
        State.remove_events track_id start end
        State.insert_events track_id events

cmd_paste_merge :: (Cmd.M m) => m ()
cmd_paste_merge = do
    (_, _, track_events) <- paste_info
    forM_  track_events $ \(track_id, events) ->
        State.insert_events track_id events

-- | Like 'cmd_paste_merge', except don't merge events that overlap with
-- existing ones.
cmd_paste_soft_merge :: (Cmd.M m) => m ()
cmd_paste_soft_merge = do
    (_, _, track_events) <- paste_info
    forM_  track_events $ \(track_id, events) -> do
        track_events <- fmap Track.track_events (State.get_track track_id)
        State.insert_events track_id $
            filter (not . overlaps track_events) events
    where
    overlaps events (pos, _) = Maybe.isJust (Events.overlapping pos events)

-- | Insert the events after pushing events after the selection down by
-- the inserted length, which is the minimum of the insert selection and the
-- length of the buffer.
cmd_paste_insert :: (Cmd.M m) => m ()
cmd_paste_insert = do
    (start, end, track_events) <- paste_info
    -- Only shift the tracks that are in clip_events.
    mapM_ (ModifyEvents.move_track_events start (end-start))
        (map fst track_events)
    forM_  track_events $ \(track_id, events) ->
        State.insert_events track_id events


-- * implementation

get_clip_block_id :: (Cmd.M m) => m BlockId
get_clip_block_id = do
    clip_ns <- get_clip_namespace
    return $ Types.BlockId (Id.unsafe_id clip_ns Config.clip_block_name)

-- ** copy

-- *** namespace

-- | Rename the blocks and tracks in the given state into the given namespace
-- and replace the IDs already in that namespace with it.  Rulers are ignored.
--
-- This means that if the given state has IDs in more than one namespace, they
-- will be flattened into one.  Any collisions will throw an exception.
state_to_namespace :: (State.M m) => State.State -> Id.Namespace -> m ()
state_to_namespace state ns = do
    destroy_namespace ns
    state2 <- set_namespace ns state
    global_st <- State.get
    merged <- State.require_right "merge states"
        (Transform.merge_states global_st state2)
    State.put merged

-- | Set all the IDs in the state to be in the given namespace, except rulers.
-- Collisions will throw.  Rulers are omitted because copy and paste doesn't
-- mess with rulers.
set_namespace :: (State.M m) => Id.Namespace -> State.State -> m State.State
set_namespace ns state = do
    let state2 = state { State.state_rulers = Map.empty }
    State.require_right "set to clip namespace" $ State.exec state2 $ do
        Transform.map_view_ids (Id.set_namespace ns)
        Transform.map_block_ids (Id.set_namespace ns)
        Transform.map_track_ids (Id.set_namespace ns)

get_clip_namespace :: (Cmd.M m) => m Id.Namespace
get_clip_namespace = Cmd.gets Cmd.state_clip_namespace

-- | Destroy all views, blocks, tracks, and rulers with the given namespace.
-- TODO move this to Ui.State?
destroy_namespace :: (State.M m) => Id.Namespace -> m ()
destroy_namespace ns = do
    let in_ns = ((==ns) . Id.id_namespace)
    block_ids <- fmap (filter (in_ns . Id.unpack_id))
        State.get_all_block_ids
    blocks <- mapM State.get_block block_ids
    let track_ids = Seq.unique $ concatMap Block.block_track_ids blocks
        ruler_ids = Seq.unique $ concatMap Block.block_ruler_ids blocks
    -- Will destroy any views too.
    mapM_ State.destroy_block block_ids
    mapM_ State.destroy_track (filter (in_ns . Id.unpack_id) track_ids)
    mapM_ State.destroy_ruler (filter (in_ns . Id.unpack_id) ruler_ids)

-- ** paste

-- | Get the info necessary to paste from the clipboard: start and end pos,
-- the tracks in the destination selection, and the events from the clipboard
-- paired with the track it should go into.  The clipboard events are truncated
-- to start--end and shifted into the paste range.
paste_info :: (Cmd.M m) =>
    m (ScoreTime, ScoreTime, [(TrackId, [Events.PosEvent])])
paste_info = do
    (track_ids, clip_track_ids, start, end) <- get_paste_area
    clip_events <- mapM (clip_track_events start end) clip_track_ids
    return (start, end, zip track_ids clip_events)

clip_track_events :: (State.M m) =>
    ScoreTime -> ScoreTime -> TrackId -> m [Events.PosEvent]
clip_track_events start end track_id = do
    track <- State.get_track track_id
    let events = clip_events (end-start)
            (Events.ascending (Track.track_events track))
        shifted = map (\(pos, evt) -> (pos+start, evt)) events
    return shifted

clip_events :: ScoreTime -> [Events.PosEvent] -> [Events.PosEvent]
clip_events _ [] = []
clip_events point (event@(pos, evt):events)
    | pos >= point = []
    | Events.end event > point =
        [(pos, Event.modify_duration (\d -> min d (point - pos)) evt)]
    | otherwise = event : clip_events point events

-- | Get the destination and clip tracks involved in a paste, along with the
-- paste selection.
--
-- During pastes, a point selection extends to the end of the last pasted
-- event.
get_paste_area :: (Cmd.M m) => m ([TrackId], [TrackId], ScoreTime, ScoreTime)
get_paste_area = do
    (_, tracknums, track_ids, start, end) <- Selection.tracks
    clip_block_id <- get_clip_block_id
    clip_block <- State.get_block clip_block_id
    -- If the clip block has any rulers or anything, I skip them.
    let clip_track_ids =
            take (length tracknums) (Block.block_track_ids clip_block)
    clip_end <- State.block_event_end clip_block_id
    return (track_ids, clip_track_ids, start,
        if start == end then start + clip_end else end)
