-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE ViewPatterns #-}
{- | Cmds to edit a pitch track, which is a special kind of control track.

    This module creates the pitches that are later parsed by Derive.Control.
-}
module Cmd.PitchTrack (module Cmd.PitchTrack, module Cmd.ControlTrack) where
import qualified Data.Text as Text

import qualified Util.Seq as Seq
import qualified Ui.Event as Event
import qualified Ui.Key as Key
import qualified Cmd.Cmd as Cmd
import qualified Cmd.ControlTrack as ControlTrack
import Cmd.ControlTrack (Event(..))
import qualified Cmd.EditUtil as EditUtil
import qualified Cmd.InputNote as InputNote
import qualified Cmd.ModifyEvents as ModifyEvents
import qualified Cmd.Msg as Msg
import qualified Cmd.Perf as Perf
import qualified Cmd.Selection as Selection

import qualified Derive.BaseTypes as BaseTypes
import qualified Derive.Env as Env
import qualified Derive.Expr as Expr
import qualified Derive.Parse as Parse
import qualified Derive.ParseTitle as ParseTitle
import qualified Derive.Scale as Scale
import qualified Derive.Symbols as Symbols

import qualified Perform.Pitch as Pitch
import qualified App.Config as Config
import Global


-- * entry

-- | Val edit turns 'Msg.InputNote's into the appropriate scale degree call
-- for the scale in scope.
--
-- Like control tracks, @'@ will add a @'@ call, which repeats the last value.
-- This is useful to extend a constant pitch value to the desired breakpoint.
cmd_val_edit :: Cmd.M m => Msg.Msg -> m Cmd.Status
cmd_val_edit msg = Cmd.suppress_history Cmd.ValEdit "pitch track val edit" $ do
    EditUtil.fallthrough msg
    case msg of
        Msg.InputNote (InputNote.NoteOn _ input _) -> do
            pos <- EditUtil.get_pos
            note <- EditUtil.input_to_note input
            val_edit_at pos note
            whenM (Cmd.gets (Cmd.state_advance . Cmd.state_edit))
                Selection.advance
        Msg.InputNote (InputNote.PitchChange _ input) -> do
            pos <- EditUtil.get_pos
            note <- EditUtil.input_to_note input
            val_edit_at pos note
        (Msg.key_down -> Just (Key.Char '\'')) -> EditUtil.soft_insert "'"
        (Msg.key_down -> Just Key.Backspace) -> EditUtil.remove_event True
        _ -> Cmd.abort
    return Cmd.Done

-- | Method edit directs keystrokes to the (optional) call around the pitch
-- call.  Pitches by themselves simply set a constant pitch by default, but
-- a call can create an interpolated curve, or a trill, or anything really.
cmd_method_edit :: Cmd.M m => Msg.Msg -> m Cmd.Status
cmd_method_edit msg = Cmd.suppress_history Cmd.MethodEdit
        "pitch track method edit" $ do
    EditUtil.fallthrough msg
    case msg of
        (EditUtil.method_key -> Just key) -> do
            pos <- EditUtil.get_pos
            method_edit_at pos key
        _ -> Cmd.abort
    return Cmd.Done

val_edit_at :: Cmd.M m => EditUtil.Pos -> Pitch.Note -> m ()
val_edit_at pos note = modify_event_at pos $ \event ->
    (Just $ event { event_val = Pitch.note_text note }, False)

method_edit_at :: Cmd.M m => EditUtil.Pos -> EditUtil.Key -> m ()
method_edit_at pos key = modify_event_at pos $ \event ->
    (Just $ event { event_method = fromMaybe "" $
            EditUtil.modify_text_key [] key (event_method event) },
        False)

-- | Record the last note entered.  Should be called by 'with_note'.
cmd_record_note_status :: Cmd.M m => Msg.Msg -> m Cmd.Status
cmd_record_note_status msg = do
    case msg of
        Msg.InputNote (InputNote.NoteOn _ input _) -> do
            note <- EditUtil.input_to_note input
            Cmd.set_status Config.status_note $ Just $ Pitch.note_text note
        _ -> return ()
    return Cmd.Continue

-- * implementation

-- | old_event -> (new_event, advance?)
type Modify = Event -> (Maybe Event, Bool)

modify_event_at :: Cmd.M m => EditUtil.Pos -> Modify -> m ()
modify_event_at pos f = EditUtil.modify_event_at pos True True
    (first (fmap unparse) . f . parse . fromMaybe "")

-- | Modify event text.  This is not used within this module but is exported
-- for others as a more general variant of 'modify_event_at'.
modify :: (Event -> Event) -> Event.Event -> Event.Event
modify f = Event.text_ %= unparse . f . parse

-- | Like 'ControlTrack.parse', but complicated by the fact that pitch calls
-- can take args.
--
-- > "x"        -> Event { method = "", val = "x", args = "" }
-- > "x "       -> Event { method = "x", val = "", args = "" }
-- > "x y"      -> Event { method = "", val = "x y", args = "" }
-- > "x (y)"    -> Event { method = "x", val = "(y)", args = "" }
-- > "x (y) z"  -> Event { method = "x", val = "(y)", args = "z" }
parse :: Text -> Event
parse s
    | Text.null post = Event "" pre ""
    | post == " " = Event pre "" ""
    | " (" `Text.isPrefixOf` post =
        ControlTrack.split_args pre (Text.drop 1 post)
    | otherwise = Event "" s ""
    where (pre, post) = Text.break (==' ') s

-- | This is a bit more complicated than 'ControlTrack.unparse', since it needs
-- to add or strip parens.
unparse :: Event -> Text
unparse (ControlTrack.Event method val args)
    | Text.null method && Text.null val = ""
    -- If the method is gone, the note no longer needs its parens.
    | Text.null method = strip_parens val
    | otherwise = Text.unwords $
        method : add_parens val : if Text.null args then [] else [args]
    where
    strip_parens t
        | "(" `Text.isPrefixOf` t && ")" `Text.isSuffixOf` t =
            Text.drop 1 $ Text.take (Text.length t - 1) t
        | otherwise = t
    -- If there's a method and it doesn't already have parens, it'll need them.
    add_parens val
        | Text.null val || "(" `Text.isPrefixOf` val = val
        | otherwise = "(" <> val <> ")"

-- | Try to figure out where the pitch call part is in event text and modify
-- that with the given function.  The function can signal failure by returning
-- Left.
--
-- This is a bit of a heuristic because by design a pitch is a normal call and
-- there's no syntactic way to tell where the pitches are in an expression.  If
-- the text is a call with a val call as its first argument, that's considered
-- the pitch call.  Otherwise, if the text is just a call, that's the pitch
-- call.  Otherwise the text is unchanged.
--
-- This works with the convention that pitch calls take the \"base\" pitch as
-- their first argument.
modify_note :: (Pitch.Note -> Either Text Pitch.Note) -> Text
    -> Either Text Text
modify_note f = modify_expr $ \note_str -> case Text.uncons note_str of
    Just ('(', rest) ->
        let (note, post) = Text.break (`elem` (" )" :: [Char])) rest
        in Text.cons '(' . (<>post) . Pitch.note_text <$> f (Pitch.Note note)
    _ -> Pitch.note_text <$> f (Pitch.Note note_str)

-- | Modify the note expression, e.g. in @i (a b c)@ it would be @(a b c)@,
-- including the parens.
modify_expr :: (Text -> Either Text Text) -> Text -> Either Text Text
modify_expr f text = case Parse.parse_expr text of
    Left _ -> Right text
    Right expr -> case expr of
        Expr.Call sym (Expr.ValCall _ : _) :| []
            | sym /= Symbols.equal ->
                let (pre, within) = Text.break (=='(') text
                    (note, post) = break1 (==')') within
                in (\n -> pre <> n <> post) <$> f note
        Expr.Call sym _ :| []
            | sym /= Symbols.equal ->
                let (pre, post) = Text.break (==' ') text
                in (<>post) <$> f pre
        _ -> Right text

    where
    break1 f t = case Text.findIndex f t of
        Just i -> Text.splitAt (i+1) t
        Nothing -> (t, "")


-- * edits

-- | Function that modifies the pitch of an event on a pitch track, or a Left
-- if the operation failed.
type ModifyPitch =
    Scale.Scale -> Env.Environ -> Pitch.Note -> Either Text Pitch.Note

transpose_selection :: Cmd.M m => Scale.Transposition -> Pitch.Octave
    -> Pitch.Step -> m ()
transpose_selection transposition oct steps =
    pitches $ transpose transposition oct steps

transpose :: Scale.Transposition -> Pitch.Octave -> Pitch.Step -> ModifyPitch
transpose transposition octaves steps = \scale env note ->
    case Scale.transpose transposition scale env octaves steps note of
        -- Leave non-pitches alone.
        Left BaseTypes.UnparseableNote -> Right note
        Left err -> Left (pretty err)
        Right note2 -> Right note2

cycle_enharmonics :: ModifyPitch
cycle_enharmonics scale env note = first pretty $ do
    enharmonics <- Scale.scale_enharmonics scale env note
    return $ fromMaybe note (Seq.head enharmonics)

pitches :: Cmd.M m => ModifyPitch -> m ()
pitches = ModifyEvents.selection . pitch_tracks

-- | Apply a ModifyPitch to only pitch tracks.
pitch_tracks :: Cmd.M m => ModifyPitch -> ModifyEvents.Track m
pitch_tracks f = ModifyEvents.tracks_named ParseTitle.is_pitch_track $
        \block_id track_id events -> do
    scale <- Perf.get_scale (block_id, Just track_id)
    env <- Perf.get_environ (block_id, Just track_id)
    let modify = modify_note (f scale env)
    ModifyEvents.failable_text modify block_id track_id events
