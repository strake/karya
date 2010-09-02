{-# LANGUAGE ViewPatterns #-}
{- | Cmds to add notes to a note track.

    This module is sister to 'Derive.Note' since it edits events that
    Derive.Note parses.
-}
module Cmd.NoteTrack where
import qualified Data.Map as Map
import qualified Util.Control as Control

import Ui
import qualified Ui.Key as Key
import qualified Ui.State as State

import qualified Cmd.Cmd as Cmd
import qualified Cmd.Create as Create
import qualified Cmd.EditUtil as EditUtil
import qualified Cmd.InputNote as InputNote
import qualified Cmd.Msg as Msg
import qualified Cmd.PitchTrack as PitchTrack
import qualified Cmd.Selection as Selection

import qualified Perform.Pitch as Pitch


-- | Indicate the pitch track of a note track, or how to create one if
-- necessary.
data PitchTrack =
    -- | Create a pitch track with (note_tracknum, title, pitch_tracknum).
    CreateTrack TrackNum String TrackNum
    | ExistingTrack TrackNum
    deriving (Show, Eq)

cmd_raw_edit :: Pitch.ScaleId -> Cmd.Cmd
cmd_raw_edit = EditUtil.raw_edit False

cmd_val_edit :: PitchTrack -> Pitch.ScaleId -> Cmd.Cmd
cmd_val_edit pitch_track scale_id msg = do
    EditUtil.fallthrough msg
    (block_id, tracknum, track_id, pos) <- Selection.get_insert
    case msg of
        Msg.InputNote input_note -> case input_note of
            InputNote.NoteOn note_id key _vel -> do
                -- TODO if I can find a vel track, put the vel there
                (pitch_tracknum, track_id) <-
                    make_pitch_track (Just note_id) pitch_track
                note <- EditUtil.parse_key scale_id key
                PitchTrack.val_edit_at (pitch_tracknum, track_id, pos) note
                -- TODO if I do chords, this will have to be the chosen note
                -- track
                ensure_exists
            InputNote.PitchChange note_id key -> do
                (tracknum, track_id) <- track_of note_id
                note <- EditUtil.parse_key scale_id key
                PitchTrack.val_edit_at (tracknum, track_id, pos) note
            InputNote.NoteOff note_id _vel -> do
                delete_note_id note_id
                Control.whenM all_keys_up Selection.advance
            InputNote.Control _ _ _ -> return ()
        (Msg.key_down -> Just Key.Backspace) -> do
            remove (tracknum, track_id, pos)
            -- clear out the pitch track too
            case pitch_track of
                ExistingTrack tracknum -> do
                    track_id <- State.get_event_track_at
                        "NoteTrack.cmd_val_edit" block_id tracknum
                    remove (tracknum, track_id, pos)
                _ -> return ()
            Selection.advance
        _ -> Cmd.abort
    return Cmd.Done
    where
    delete_note_id note_id = do
        st <- Cmd.get_wdev_state
        Cmd.set_wdev_state $ st { Cmd.wdev_note_track =
            Map.delete note_id (Cmd.wdev_note_track st) }

cmd_method_edit :: PitchTrack -> Cmd.Cmd
cmd_method_edit pitch_track msg = do
    EditUtil.fallthrough msg
    case msg of
        (EditUtil.method_key -> Just key) -> do
            (_, _, pos) <- EditUtil.get_sel_pos
            (tracknum, track_id) <- make_pitch_track Nothing pitch_track
            PitchTrack.method_edit_at (tracknum, track_id, pos) key
            ensure_exists
        _ -> Cmd.abort
    return Cmd.Done

all_keys_up :: (Monad m) => Cmd.CmdT m Bool
all_keys_up = do
    st <- Cmd.get_wdev_state
    return (Map.null (Cmd.wdev_note_track st))

-- | Find existing tracknum or throw.
track_of :: (Monad m) => InputNote.NoteId -> Cmd.CmdT m (TrackNum, TrackId)
track_of note_id = do
    st <- Cmd.get_wdev_state
    (block_id, tracknum) <- maybe
        (Cmd.throw $ "no tracknum for " ++ show note_id) return
        (Map.lookup note_id (Cmd.wdev_note_track st))
    track_id <- State.get_event_track_at "NoteTrack.track_of" block_id tracknum
    return (tracknum, track_id)

-- | Turn the given PitchTrack into a TrackId, creating a new track if it's
-- a CreateTrack.  If a NoteId is given, associate that ID with the track.
make_pitch_track :: (Monad m) => Maybe InputNote.NoteId -> PitchTrack
    -> Cmd.CmdT m (TrackNum, TrackId)
make_pitch_track maybe_note_id pitch_track = do
    block_id <- Cmd.get_focused_block
    (tracknum, tid) <- case pitch_track of
        CreateTrack note_tracknum title pitch_tracknum -> do
            tid <- create_pitch_track block_id note_tracknum title
                pitch_tracknum
            return (pitch_tracknum, tid)
        ExistingTrack tracknum -> do
            tid <- State.get_event_track_at "NoteTrack.make_pitch_track"
                block_id tracknum
            return (tracknum, tid)
    st <- Cmd.get_wdev_state
    case maybe_note_id of
        Just note_id -> Cmd.set_wdev_state $ st { Cmd.wdev_note_track =
            Map.insert note_id (block_id, tracknum) (Cmd.wdev_note_track st) }
        _ -> return ()
    return (tracknum, tid)

-- | Create a pitch track for a note track.
create_pitch_track :: (State.UiStateMonad m) => BlockId
    -> TrackNum -- ^ tracknum of corresponding note track
    -> String -- ^ created track has this title
    -> TrackNum -> m TrackId
create_pitch_track block_id note_tracknum title tracknum = do
    tid <- Create.track block_id tracknum
    -- Link note track underneath newly created pitch track.
    State.splice_skeleton block_id (tracknum, note_tracknum)
    State.set_track_title tid title
    return tid

-- * implementation

ensure_exists :: (Monad m) => Cmd.CmdT m ()
ensure_exists = EditUtil.modify_event False True $ \txt -> (Just txt, False)

remove :: (Monad m) => EditUtil.SelPos -> Cmd.CmdT m ()
remove selpos =
    EditUtil.modify_event_at selpos False False (const (Nothing, False))
