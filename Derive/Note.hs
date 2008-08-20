{-# OPTIONS_GHC -fno-warn-unused-imports #-}
-- Control.Monad
{- | Derive events on a note track.  This is the Derive equivalent of
    'Cmd.NoteTrack', but has a different name to avoid clashes.

    Note tracks have a \"function call\" abstraction mechanism.  An event in
    one block is expanded into the events derived from the block it names, and
    so on recursively.

    The sub-block is passed its parent's tempo map (along with all the other
    controllers in the environment) to interpret as it will, so that it may,
    for example, set absolute tempo.  The generated events should begin with
    the given start time, but are not guaranteed to last for the given
    duration.

    The parse section parses note track events as manipulated by
    'Cmd.NoteTrack'.
-}
module Derive.Note where
import Control.Monad
import qualified Control.Monad.Identity as Identity
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Text.ParserCombinators.Parsec as P

import Util.Control ((#>>))
import qualified Util.Log as Log
import Util.Seq as Seq

import Ui.Types
import qualified Ui.Block as Block
import qualified Ui.Event as Event
import qualified Ui.Id as Id
import qualified Ui.State as State
import qualified Ui.Track as Track

import qualified Derive.Controller as Controller
import qualified Derive.Derive as Derive
import qualified Derive.Score as Score

import qualified Perform.Pitch as Pitch
import qualified Perform.Signal as Signal

import Util.Debug


type NoteParser m = Track.PosEvent
    -> Derive.DeriveT m (Maybe (Signal.Method, Pitch.Pitch), Maybe String)

-- * instrument track

d_note_track :: (Monad m) => Pitch.ScaleMap -> NoteParser m
    -> Derive.TrackDeriver m
d_note_track scales note_parser track_id = do
    track <- Derive.get_track track_id
    let events = Track.event_list (Track.track_events track)
    parsed <- parse_events note_parser events
    pitch_signal <- extract_pitch_signal scales parsed
    Derive.with_controller Score.pitch pitch_signal (derive_notes parsed)

data ParsedEvent = ParsedEvent {
    parsed_text :: String
    , parsed_start :: TrackPos
    , parsed_dur :: TrackPos
    , parsed_pitch :: Maybe (Signal.Method, Pitch.Pitch)
    , parsed_call :: Maybe String
    } deriving (Show)

derive_notes :: (Monad m) => [ParsedEvent] -> Derive.DeriveT m [Score.Event]
derive_notes parsed = fmap concat (mapM note parsed)
    where
    note parsed = Derive.with_stack_pos
        (parsed_start parsed) (parsed_dur parsed) (derive_note parsed)

derive_note :: (Monad m) => ParsedEvent -> Derive.DeriveT m [Score.Event]
derive_note parsed = do
    -- TODO when signals are lazy this will be inefficient.  I need to come
    -- up with a way to guarantee such accesses are increasing and let me gc
    -- the head.
    start <- Derive.local_to_global (parsed_start parsed)
    end <- Derive.local_to_global (parsed_start parsed + parsed_dur parsed)
    st <- Derive.get
    case parsed_call parsed of
        Nothing -> return [Score.Event start (end-start) (parsed_text parsed)
            (Derive.state_controllers st) (Derive.state_stack st)
            (Derive.state_instrument st)]
        -- d_call will set shift and stretch which is in local time, so pass
        -- local rather than global.
        Just call -> Derive.d_sub_derive []
            (d_call (parsed_start parsed) (parsed_dur parsed) call)

d_call :: TrackPos -> TrackPos -> String -> Derive.EventDeriver
d_call start dur ident = do
    -- TODO also I'll want to support generic calls
    default_ns <- fmap (State.state_project . Derive.state_ui) Derive.get
    let block_id = Block.BlockId (make_id default_ns ident)
    stack <- fmap Derive.state_stack Derive.get
    -- Since there is no branching, any recursion will be endless.
    when (block_id `elem` [bid | (bid, _, _) <- stack]) $
        Derive.throw $ "recursive block derivation: " ++ show block_id
    -- Stretch call to fit in duration, based on the block length.
    -- An alternate approach would be no stretch, but just clip, but I'm
    -- not sure how to indicate that kind of derivation.
    -- This is actually the only thing that requires block_id name a real
    -- block.
    ui_state <- fmap Derive.state_ui Derive.get
    block_dur <- either (Derive.throw . ("getting block end: "++) . show)
        return (State.eval ui_state (State.ruler_end block_id))
    if block_dur > TrackPos 0
        then Derive.d_at start (Derive.d_stretch (dur/block_dur)
            (Derive.d_block block_id))
        else do
            Log.warn $ "block with zero duration: " ++ Id.show_ident block_id
            return []

-- | Make an Id from a string, relative to the current ns if it doesn't already
-- have one.
--
-- TODO move this to a more generic place since LanguageCmds may want it to?
make_id :: String -> String -> Id.Id
make_id default_ns ident_str = Id.id ns ident
    where
    (w0, w1) = break (=='/') ident_str
    (ns, ident) = if null w1 then (default_ns, w0) else (w0, drop 1 w1)

parse_events :: (Monad m) => NoteParser m -> [Track.PosEvent]
    -> Derive.DeriveT m [ParsedEvent]
parse_events note_parser events = do
    maybe_parsed <- mapM derive_event (map note_parser events)
    return
        [ ParsedEvent (Event.event_text event) start
            (Event.event_duration event) pitch call
        | ((start, event), Just (pitch, call)) <- zip events maybe_parsed]

extract_pitch_signal :: (Monad m) => Pitch.ScaleMap -> [ParsedEvent]
    -> Derive.DeriveT m Signal.Signal
extract_pitch_signal scales parsed = do
    let pitch_points =
            [ (start, method, pitch, pitch_to_val scales pitch)
            | ParsedEvent { parsed_start = start,
                parsed_pitch = Just (method, pitch) } <- parsed ]
        pos_list = map parsed_start parsed
        errors = [(pos, pitch) | (pos, _, pitch, Nothing) <- pitch_points]
    unless (null errors) $
        -- This should never happen.
        Log.warn $ "notes not part of their scales: " ++ show errors
    -- TODO this won't be efficient with a lazy signal because I need to
    -- compute it incrementally.
    warped <- mapM Derive.local_to_global pos_list
    return $ Signal.track_signal Signal.default_srate
        [ (pos, method, val)
        | (pos, (_, method, _, Just val)) <- zip warped pitch_points ]

-- | Convert the Pitch to a signal val.  This loses information, such as scale.
-- I think I'll need to get it back to e.g. transpose by scale degree, but
-- I'll worry about that later.
-- TODO
pitch_to_val :: Pitch.ScaleMap -> Pitch.Pitch -> Maybe Signal.Val
pitch_to_val scales pitch = do
    scale <-  Map.lookup (Pitch.pitch_scale pitch) scales
    Pitch.NoteNumber nn <- Pitch.scale_to_nn scale (Pitch.pitch_note pitch)
    return nn

derive_event :: (Monad m) => Derive.DeriveT m a -> Derive.DeriveT m (Maybe a)
derive_event deriver = Derive.catch_warn deriver


-- * parser

-- | The idea is that a more complicated note parser may get scale values out
-- of the environment or something.
scale_parser :: (Monad m) => Pitch.Scale -> NoteParser m
scale_parser scale (_pos, event) =
    case parse_note scale (Event.event_text event) of
        Left err -> Derive.throw err
        Right parsed -> return parsed

-- | Try to parse a note track event.  It's a little finicky because
-- I want to be unambiguous but also not ugly.  I think I can manage that by
-- using \< to disambiguate a call and not allowing (method, \"\", call).
--
-- TODO Unfortunately I still have a problem with shift since I can't type _,
-- but I'll deal with that later if it becomes a problem.
--
-- > i, scl, block -> ((i, scl), block))
-- > i, scl -> ((i, scl), Nothing)
-- > 2.4e, 7c#
-- > scl -> ((Set, scl), Nothing)
-- > \<block -> (Nothing, block)
-- > , , block -> (Nothing, block)
--
parse_note :: Pitch.Scale -> String
    -> Either String (Maybe (Signal.Method, Pitch.Pitch), Maybe String)
parse_note scale text = do
    (method_s, pitch_s, call) <- tokenize_note text
    if null pitch_s then return (Nothing, to_maybe call) else do
    method <- if null method_s
        then Right Signal.Set else parse_method method_s
    pitch <- maybe (Left ("note not in scale: " ++ show pitch_s)) Right
        (Pitch.pitch scale pitch_s)
    return (Just (method, pitch), to_maybe call)
    where
    to_maybe s = if null s then Nothing else Just s
    parse_method s = case P.parse (Controller.p_method #>> P.eof) "" s of
        Left _ -> Left $ "couldn't parse method: " ++ show s
        Right v -> Right v

tokenize_note :: String -> Either String (String, String, String)
tokenize_note text = fmap drop_third $ case Seq.split ", " text of
    [w0]
        | is_call w0 -> Right ("", "", w0)
        | otherwise -> Right ("", w0, "")
    [w0, w1]
        | is_call w1 -> Right ("", w0, w1)
        | otherwise -> Right (w0, w1, "")
    [w0, w1, w2] -> Right (w0, w1, w2)
    _ -> Left "too many words in note"
    where
    is_call = (=="<") . take 1
    drop_third (a, b, c) = (a, b, drop 1 c) -- drop off the '<'

untokenize_note ("", "", "") = ""
untokenize_note ("", "", call) = '<':call
untokenize_note (note_s, pitch_s, "") = join_note [note_s, pitch_s]
untokenize_note (note_s, pitch_s, call) = join_note [note_s, pitch_s, '<':call]
join_note = Seq.join ", " . filter (not . null)


-- One of the early proponents of this style during the renaissance was
-- Johannes Fux, who was surpassed in unfortunateness only by the much-loved
-- Count Fux Dux.
