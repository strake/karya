-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE ViewPatterns #-}
{- | Cmds to add notes to a note track.

    This module is sister to "Derive.Note" since it edits events that
    Derive.Note parses.

    Note events are usually given a duration of the current time step.  If a
    "trigger only" instrument (e.g. percussion) is in scope, they are created
    with zero duration.  Also, starting a raw edit with space will create a
    zero duration event.
-}
module Cmd.NoteTrack where
import qualified Data.List as List
import qualified Data.Map as Map

import qualified Util.Seq as Seq
import qualified Ui.Event as Event
import qualified Ui.Events as Events
import qualified Ui.Id as Id
import qualified Ui.Key as Key
import qualified Ui.Sel as Sel
import qualified Ui.Types as Types
import qualified Ui.Ui as Ui

import qualified Cmd.Cmd as Cmd
import qualified Cmd.ControlTrack as ControlTrack
import qualified Cmd.Create as Create
import qualified Cmd.EditUtil as EditUtil
import qualified Cmd.Info as Info
import qualified Cmd.InputNote as InputNote
import qualified Cmd.Msg as Msg
import qualified Cmd.PitchTrack as PitchTrack
import qualified Cmd.Selection as Selection

import qualified Derive.Eval as Eval
import qualified Derive.Expr as Expr
import qualified Derive.Parse as Parse
import qualified Derive.ParseTitle as ParseTitle
import qualified Derive.Score as Score

import qualified Perform.Midi.Patch as Patch
import qualified App.Config as Config
import Global
import Types


-- * val edit

-- | A control track belonging to the note track.  This can be a pitch track,
-- or a dyn track.
data ControlTrack = ControlTrack {
    track_note :: TrackNum
    , track_control :: TrackNum
    } deriving (Show, Eq)

-- | The val edit for note tracks edits its pitch track (possibly creating one
-- if necessary), and creates a blank event on the note track.  It may also
-- edit multiple pitch tracks for chords, or record velocity in addition to
-- pitch.
--
-- If I'm in chord mode, try to find the next track and put notes there.  If
-- there is no appropriate next track, the cmd will throw an error.
cmd_val_edit :: Cmd.M m => Msg.Msg -> m Cmd.Status
cmd_val_edit msg = Cmd.suppress_history Cmd.ValEdit "note track val edit" $ do
    EditUtil.fallthrough msg
    EditUtil.Pos block_id sel_tracknum pos dur <- EditUtil.get_pos
    case msg of
        Msg.InputNote input_note -> case input_note of
            InputNote.NoteOn note_id input vel -> do
                note <- EditUtil.input_to_note input
                note_on block_id sel_tracknum pos dur note_id note vel
            InputNote.PitchChange note_id input -> do
                (pitch_tracknum, track_id) <- Cmd.require
                    ("no track for note_id " <> showt note_id)
                    =<< find_pitch_track note_id
                note <- EditUtil.input_to_note input
                -- If advance is set, the selection may have advanced past
                -- the pitch's position, so look for a previous event.
                pos <- event_pos_at_or_before track_id pos
                PitchTrack.val_edit_at
                    (EditUtil.Pos block_id pitch_tracknum pos dur) note
            InputNote.NoteOff note_id _vel -> do
                dissociate_note_id note_id
                chord_done <- andM [get_state Cmd.state_chord, all_keys_up]
                when chord_done $ set_temp_sel pos Nothing
                whenM (andM [return chord_done, get_state Cmd.state_advance])
                    Selection.advance
            InputNote.Control {} -> return ()
        (Msg.key_down -> Just Key.Backspace) -> do
            EditUtil.remove_event_at
                (EditUtil.Pos block_id sel_tracknum pos 0) False
            -- Clear out the pitch track too.
            maybe_pitch <- Info.pitch_of_note block_id sel_tracknum
            whenJust maybe_pitch $ \pitch -> EditUtil.remove_event_at
                (EditUtil.Pos block_id (Ui.track_tracknum pitch) pos 0) False
            Selection.advance
        _ -> Cmd.abort
    return Cmd.Done
    where
    -- NoteOn handling is especially complicated.
    note_on block_id sel_tracknum pos dur note_id note vel = do
        chord_mode <- get_state Cmd.state_chord
        -- Pitch track.
        (ctrack, create) <- if chord_mode
            then do
                (ctrack, create, maybe_next) <-
                    next_control_track block_id sel_tracknum is_pitch
                set_temp_sel pos maybe_next
                return (ctrack, create)
            else this_control_track block_id sel_tracknum is_pitch
        when create $ create_pitch_track block_id ctrack
        associate_note_id block_id (track_control ctrack) note_id
        orient <- Cmd.gets (Cmd.state_note_orientation . Cmd.state_edit)
        let pitch_pos = EditUtil.Pos block_id (track_control ctrack)
                pos (if orient == Types.Positive then 0 else -0)
        PitchTrack.val_edit_at pitch_pos note
        -- Dyn track.
        whenM (get_state Cmd.state_record_velocity) $ do
            (dtrack, create) <- if chord_mode
                then (\(a, b, _) -> (a, b)) <$>
                    next_control_track block_id sel_tracknum is_dyn
                else this_control_track block_id sel_tracknum is_dyn
            when create $ create_dyn_track block_id dtrack
            ControlTrack.val_edit_at
                (EditUtil.Pos block_id (track_control dtrack) pos 0) vel

        -- Create note and advance.
        ensure_note_event (EditUtil.Pos block_id (track_note ctrack) pos dur)
        advance_mode <- get_state Cmd.state_advance
        when (advance_mode && not chord_mode) Selection.advance

    is_pitch = ParseTitle.is_pitch_track
    is_dyn = (== Just Score.c_dynamic) . ParseTitle.title_to_control
    set_temp_sel pos maybe_tracknum = Selection.set_current
        Config.temporary_insert_selnum $
            fmap (\num -> Sel.point num pos Sel.Positive) maybe_tracknum
    dissociate_note_id note_id = Cmd.modify_wdev_state $ \st -> st
        { Cmd.wdev_pitch_track = Map.delete note_id (Cmd.wdev_pitch_track st) }
    associate_note_id block_id tracknum note_id = Cmd.modify_wdev_state $
        \st -> st { Cmd.wdev_pitch_track =
            Map.insert note_id (block_id, tracknum) (Cmd.wdev_pitch_track st) }

-- | Find the next available control track.  Available means it is the given
-- track or is to its right, has either the same instrument or has the default
-- instrument, and doesn't already have a note_id associated with it.
--
-- If none is found, return the tracknum at which one should be created.
next_control_track :: Cmd.M m => BlockId -> TrackNum -> (Text -> Bool)
    -> m (ControlTrack, Bool, Maybe TrackNum)
    -- ^ (selected_track_pair, should_create, next_control_track)
next_control_track block_id tracknum is_control = do
    wdev <- Cmd.get_wdev_state
    let associated =
            [tracknum | (_, tracknum) <- Map.elems (Cmd.wdev_pitch_track wdev)]
    tracks <- Info.block_tracks block_id
    inst <- Info.get_instrument_of block_id tracknum
    let find right_of = findM (candidate inst associated right_of) tracks
    found <- find tracknum
    case found of
        Nothing -> Cmd.throw $ "no next note track in " <> showt block_id
        Just track -> do
            (ctrack, create) <- should_create_control block_id track is_control
            next <- find (track_control ctrack + 1)
            return (ctrack, create,
                Ui.track_tracknum . Info.track_info <$> next)
    where
    -- Wow, monads can be awkward.
    candidate inst associated right_of
            (Info.Track track (Info.Note controls _)) =
        andM
            [ return $ tracknum >= right_of
            , return $ maybe True (`notElem` associated) pitch_tracknum
            , (== Just inst) <$> Info.lookup_instrument_of block_id tracknum
            ]
        where
        tracknum = Ui.track_tracknum track
        pitch_tracknum = Ui.track_tracknum <$>
            List.find (is_control . Ui.track_title) controls
    candidate _ _ _ _ = return False

-- | The given track should be a note track.  Figure out if it has a control
-- track, or if one should be created.
this_control_track :: Cmd.M m => BlockId -> TrackNum -> (Text -> Bool)
    -> m (ControlTrack, Bool)
this_control_track block_id tracknum is_control = do
    track <- Info.get_track_type block_id tracknum
    should_create_control block_id track is_control

-- | Find the ControlTrack of the given note Track.  If there is none, return
-- the tracknum where you should create one.
should_create_control :: Cmd.M m => BlockId -> Info.Track
    -> (Text -> Bool) -> m (ControlTrack, Bool)
should_create_control block_id track is_control = case Info.track_type track of
    Info.Note controls _ -> case find controls of
        Nothing -> return (ControlTrack tracknum (tracknum+1), True)
        Just control ->
            return (ControlTrack tracknum (Ui.track_tracknum control), False)
    ttype -> Cmd.throw $ "expected a note track for "
        <> showt (block_id, tracknum) <> " but got " <> showt ttype
    where
    find = List.find (is_control . Ui.track_title)
    tracknum = Ui.track_tracknum (Info.track_info track)

event_pos_at_or_before :: Cmd.M m => TrackId -> ScoreTime -> m ScoreTime
event_pos_at_or_before track_id pos = do
    (_, events) <- Events.split_at_before pos <$> Ui.get_events track_id
    return $ maybe pos Event.start (Seq.head events)

all_keys_up :: Cmd.M m => m Bool
all_keys_up = do
    st <- Cmd.get_wdev_state
    return (Map.null (Cmd.wdev_pitch_track st))

-- | Find the pitch track associated with the given NoteId, if one exists.
find_pitch_track :: Cmd.M m => InputNote.NoteId
    -> m (Maybe (TrackNum, TrackId))
find_pitch_track note_id = do
    st <- Cmd.get_wdev_state
    let maybe_track = Map.lookup note_id (Cmd.wdev_pitch_track st)
    case maybe_track of
        Nothing -> return Nothing
        Just (block_id, tracknum) -> do
            track_id <- Ui.get_event_track_at block_id tracknum
            return $ Just (tracknum, track_id)


-- * method edit

-- | Method edit is redirected to the pitch track, creating one if necessary.
cmd_method_edit :: Cmd.M m => Msg.Msg -> m Cmd.Status
cmd_method_edit msg = Cmd.suppress_history Cmd.MethodEdit
        "note track method edit" $ do
    EditUtil.fallthrough msg
    case msg of
        (EditUtil.method_key -> Just key) -> do
            (block_id, tracknum, _, pos) <- Selection.get_insert
            (ctrack, create) <- this_control_track block_id tracknum
                ParseTitle.is_pitch_track
            when create $ create_pitch_track block_id ctrack
            PitchTrack.method_edit_at
                (EditUtil.Pos block_id (track_control ctrack) pos 0) key
            ensure_note_event (EditUtil.Pos block_id (track_note ctrack) pos 0)
        _ -> Cmd.abort
    return Cmd.Done

-- * parsing

track_block_calls :: Ui.M m => Bool -> BlockId -> TrackId
    -> m [(Event.Event, NonEmpty BlockId)]
track_block_calls look_in_args block_id track_id = do
    events <- Events.ascending <$> Ui.get_events track_id
    to_bid <- get_to_block_id (Just block_id)
    let bids = map (block_calls_of look_in_args to_bid . Event.text) events
    return [(event, b :| bs) | (event, b:bs) <- zip events bids]

expr_block_calls :: Ui.M m => Bool -> BlockId -> Text -> m [BlockId]
expr_block_calls look_in_args caller expr = do
    to_bid <- get_to_block_id (Just caller)
    return $ block_calls_of look_in_args to_bid expr

-- | Try to to figure out any blocks that are referenced in the expression.
--
-- This doesn't use the full Derive.Parse machinery, but is simple and doesn't
-- require the text to be fully parseable.
block_calls_of :: Bool -- ^ If True, and the call wasn't a block, see if any
    -- of the arguments name blocks.  This is for calls like @alt@, which take
    -- blocks as arguments.
    -> (Text -> Maybe a) -> Text -> [a]
block_calls_of look_in_args to_bid expr = case syms of
    [] -> []
    b : bs -> case to_bid b of
        Nothing -> mapMaybe to_bid bs
        Just block_id -> [block_id]
    where
    syms = (if look_in_args then id else take 1) $ possible_block_calls expr

get_to_block_id :: Ui.M m => Maybe BlockId -> m (Text -> Maybe BlockId)
get_to_block_id caller = do
    blocks <- Ui.gets Ui.state_blocks
    ns <- Ui.get_namespace
    return $ to_block_id blocks ns caller

-- | If the first word names a block, then it's probably a block call with
-- args, so return just that.  Otherwise, return any argument that names
-- a block.
to_block_id :: Map BlockId a -> Id.Namespace -> Maybe BlockId -> Text
    -> (Maybe BlockId)
to_block_id blocks ns caller =
    valid <=< Eval.call_to_block_id ns caller . Expr.Symbol
    where
    valid block_id
        | Just _ <- Map.lookup block_id blocks = Just block_id
        | otherwise = Nothing

possible_block_calls :: Text -> [Text]
possible_block_calls = fromMaybe [] . Seq.last . Parse.split_pipeline

-- * implementation

-- | Create a pitch track.
create_pitch_track :: Cmd.M m => BlockId -> ControlTrack -> m ()
create_pitch_track block_id (ControlTrack note pitch) = do
    Create.track block_id pitch "*" Events.empty
    -- Link note track underneath newly created pitch track.
    Ui.splice_skeleton_below block_id pitch note

create_dyn_track :: Cmd.M m => BlockId -> ControlTrack -> m ()
create_dyn_track block_id (ControlTrack note dyn) = do
    tid <- Create.empty_track block_id dyn
    Ui.splice_skeleton_below block_id dyn note
    Ui.set_track_title tid $
        ParseTitle.control_to_title (Score.untyped Score.c_dynamic)

-- | Ensure that a note event exists at the given spot.  An existing event is
-- left alone, but if there is no existing event a new one will be created.
ensure_note_event :: Cmd.M m => EditUtil.Pos -> m ()
ensure_note_event pos = do
    text <- Cmd.gets (Cmd.state_note_text . Cmd.state_edit)
    modify_event_at pos False False $
        maybe (Just text, False) (\old -> (Just old, False))

-- | Instruments with the triggered flag set don't pay attention to note off,
-- so I can make the duration 0.
triggered_inst :: Cmd.M m => Maybe Score.Instrument -> m Bool
triggered_inst Nothing = return False -- don't know, but guess it's not
triggered_inst (Just inst) =
    maybe False (`Patch.has_flag` Patch.Triggered)
        <$> Cmd.lookup_midi_config inst

modify_event_at :: Cmd.M m => EditUtil.Pos -> Bool -> Bool
    -> EditUtil.Modify -> m ()
modify_event_at pos zero_dur modify_dur f = do
    trigger_inst <- triggered_inst =<< EditUtil.lookup_instrument
    EditUtil.modify_event_at pos (zero_dur || trigger_inst) modify_dur f

get_state :: Cmd.M m => (Cmd.EditState -> a) -> m a
get_state f = Cmd.gets (f . Cmd.state_edit)
