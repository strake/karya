{-# LANGUAGE PatternGuards #-}
{- | A schema is a transformation from a block to a deriver.  It may intuit the
    deriver solely from the structure of the block, or it may ignore the block
    entirely if it's specialized to one particular shape of block.

    The \"schema\" step is so that each block doesn't need to have its own
    deriver ID hardcoded into it.  Instead, many blocks can share a \"schema\"
    as long as they have the same general structure.

    The @SchemaId -> Schema@ mapping looks in a hardcoded list, a custom list
    passed via static configuration, and a dynamically loaded list.  The
    assumed usage is that you experiment with new Derivers and make minor
    changes via dynamic loading, and later incorporate them into the static
    configuration.

    TODO dynamic loaded schemas are not implemented yet

    TODO Since the tempo track is global now, I should lose the tempo scope
    parsing.  Except that I'd like it to not be global, so I'll just leave this
    as-is unless I decide global after all.  TODO is it really global!?
-}
module Derive.Schema (
    -- Re-export schema types from Cmd, to pretend they're defined here.
    -- * types
    Schema(..), SchemaDeriver
    , CmdContext(..), SchemaMap

    -- * query
    , is_tempo_track
    , is_pitch_track, scale_of_track, pitch_track_prefix
    , is_inst_track, inst_of_track

    -- * lookup
    , lookup_deriver, get_signal_deriver, get_cmds

    -- * parser
    , default_parser

    -- * util
    , cmd_context
    , instrument_to_title, title_to_instrument

    -- * exported for testing
    , get_defaults, get_track_info, TrackType(..)
    , compile, compile_to_signals
) where
-- import qualified Control.Arrow as Arrow
import Control.Monad
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.List as List
import qualified Data.Tree as Tree

import qualified Util.Seq as Seq
import qualified Util.Log as Log
import qualified Util.Tree
import qualified Ui.Block as Block
import qualified Ui.Track as Track
import qualified Ui.Skeleton as Skeleton
import qualified Ui.State as State

import qualified Cmd.Cmd as Cmd
import Cmd.Cmd (Schema(..), SchemaDeriver, CmdContext(..), SchemaMap)
import qualified Cmd.ControlTrack as ControlTrack
import qualified Cmd.NoteTrack as NoteTrack
import qualified Cmd.PitchTrack as PitchTrack
import qualified Cmd.NoteEntry as NoteEntry
import qualified Cmd.MidiThru as MidiThru

import qualified Derive.Controller as Controller
import qualified Derive.Derive as Derive
import qualified Derive.Note as Note
import qualified Derive.Score as Score

import qualified Perform.Signal as Signal
import qualified Perform.Pitch as Pitch
import qualified Perform.Midi.Instrument as Instrument

import qualified Instrument.MidiDb as MidiDb

import qualified App.Config as Config


hardcoded_schemas :: SchemaMap
hardcoded_schemas = Map.fromList [(Config.schema, default_schema)]

merge_schemas :: SchemaMap -> SchemaMap -> SchemaMap
merge_schemas map1 map2 = Map.union map2 map1


-- * lookup

-- | Create a LookupDeriver function.
lookup_deriver :: SchemaMap -> State.State -> Derive.LookupDeriver
lookup_deriver schema_map ui_state block_id = State.eval ui_state $ do
    block <- State.get_block block_id
    schema <- State.lookup_id (Block.block_schema block)
        (merge_schemas hardcoded_schemas schema_map)
    schema_deriver schema block_id

-- | Get the signal deriver for the given block.  Unlike the event deriver,
-- the signal deriver is only ever local to one block, so it doesn't need
-- a lookup mechanism.
get_signal_deriver :: (State.UiStateMonad m) => SchemaMap -> Block.BlockId
    -> m Derive.SignalDeriver
get_signal_deriver schema_map block_id = do
    block <- State.get_block block_id
    schema <- State.lookup_id (Block.block_schema block)
        (merge_schemas hardcoded_schemas schema_map)
    state <- State.get
    State.eval_rethrow "get signal deriver" state
        (schema_signal_deriver schema block_id)

-- | A block's Schema also implies a set of Cmds, possibly based on the
-- focused track.  This is so that e.g. control tracks use control editing keys
-- and note tracks use note entry keys, and they can set up the midi thru
-- mapping appropriately.
get_cmds :: SchemaMap -> CmdContext -> Block.SchemaId -> [Cmd.Cmd]
get_cmds schema_map context schema_id =
    case Map.lookup schema_id (merge_schemas hardcoded_schemas schema_map) of
        Nothing -> []
        Just schema -> schema_cmds schema context

-- | Constructor for 'CmdContext'.
cmd_context :: Instrument.Config -> MidiDb.LookupMidiInstrument
    -> Cmd.EditMode -> Bool -> Maybe Block.TrackNum -> State.TrackTree
    -> CmdContext
cmd_context midi_config lookup_midi edit_mode kbd_entry focused_tracknum ttree =
    CmdContext default_inst inst_addr lookup_midi edit_mode kbd_entry
        focused_tracknum ttree
    where
    default_inst = Instrument.config_default_inst midi_config
    -- The thru cmd has to pick a single addr for a give inst, so let's just
    -- pick the lowest one.
    inst_map = Map.fromList [ (inst, minimum addrs)
        | (inst, addrs) <- Map.toList (Instrument.config_alloc midi_config)
        , not (null addrs) ]
    inst_addr = flip Map.lookup inst_map


-- * default schema

-- | The default schema is supposed to be simple but useful, and rather
-- trackerlike.
default_schema :: Schema
default_schema =
    Schema default_schema_deriver default_schema_signal_deriver default_cmds

-- ** cmds

-- | This decides what track-specific commands are in scope based on the
-- current focus and information in the CmdContext.
--
-- TODO lookup scale here and return an error if it can't be found?
default_cmds :: CmdContext -> [Cmd.Cmd]
default_cmds context = wrap $ case maybe_track_type of
        Nothing -> []
        Just (NoteTrack pitch_track) -> case edit_mode of
            Cmd.NoEdit -> []
            Cmd.RawEdit -> [with_note $ NoteTrack.cmd_raw_edit scale_id]
            Cmd.ValEdit ->
                [with_note $ NoteTrack.cmd_val_edit pitch_track scale_id]
            Cmd.MethodEdit -> [NoteTrack.cmd_method_edit pitch_track]
        Just PitchTrack -> case edit_mode of
            Cmd.NoEdit -> []
            Cmd.RawEdit -> [with_note $ PitchTrack.cmd_raw_edit scale_id]
            Cmd.ValEdit -> [with_note $ PitchTrack.cmd_val_edit scale_id]
            Cmd.MethodEdit -> [PitchTrack.cmd_method_edit]
        Just ControlTrack -> case edit_mode of
            Cmd.NoEdit -> []
            Cmd.RawEdit -> [ControlTrack.cmd_raw_edit]
            Cmd.ValEdit -> [ControlTrack.cmd_val_edit]
            Cmd.MethodEdit -> [ControlTrack.cmd_method_edit]
    where
    wrap cmds = universal ++ cmds
    universal =
        with_note (PitchTrack.cmd_record_note_status scale_id) : midi_thru
    with_note = NoteEntry.with_note kbd_entry
    edit_mode = ctx_edit_mode context
    kbd_entry = ctx_kbd_entry context

    (maybe_track_type, maybe_inst, scale_id) = get_defaults context
    midi_thru = case maybe_inst of
        Just inst -> [with_note $ MidiThru.cmd_midi_thru scale_id inst]
        Nothing -> []

get_defaults :: CmdContext
    -> (Maybe TrackType, Maybe Score.Instrument, Pitch.ScaleId)
get_defaults context = (maybe_track_type, score_inst, scale_id)
    where
    (maybe_track_type, track_inst, track_scale) =
        get_track_info (ctx_track_tree context) (ctx_focused_tracknum context)
    -- Track inst, fall back to default inst.
    score_inst = track_inst `mplus` ctx_default_inst context
    inst = join $ fmap (ctx_lookup_midi context Score.no_attrs) score_inst
    -- Track scale, fall back to track inst scale, then default inst scale,
    -- and then to the global default scale.
    scale_id = maybe Instrument.default_scale id $
        track_scale `mplus` fmap Instrument.inst_scale inst

-- | Find the type of a track and the instrument and scale in scope.
--
-- First search up the call stack, since this will yield a track that has scope
-- over the current one.  Otherwise search down, which may yield multiple
-- possibilities, but in many cases will find an appropriate one.
--
-- TODO: if this leads to weird guesses, maybe return Nothing if there are
-- two or more matches?
get_track_info :: State.TrackTree -> Maybe Block.TrackNum
    -> (Maybe TrackType, Maybe Score.Instrument, Maybe Pitch.ScaleId)
get_track_info _ Nothing = (Nothing, Nothing, Nothing)
get_track_info track_tree (Just tracknum) = case paths of
        Nothing -> (Nothing, Nothing, Nothing)
        Just (track, parents, children) ->
            let inst = find_inst (track : parents ++ children)
                scale_id = find_scale (track : parents ++ children)
            in (Just (track_type track parents), inst, scale_id)
    where
    paths = List.find ((==tracknum) . State.track_tracknum . (\(a, _, _) -> a))
        (Util.Tree.paths track_tree)
    find_inst = msum . map (title_to_instrument . State.track_title)
    find_scale = msum . map (title_to_scale . State.track_title)

-- | Describe the type of a single track.  This is used to figure out what set
-- of cmds should apply to a given track.
data TrackType =
    -- | NoteTrack is paired with the first pitch track found for it.
    NoteTrack NoteTrack.PitchTrack | PitchTrack | ControlTrack
    deriving (Show, Eq)

track_type :: State.TrackInfo -> [State.TrackInfo] -> TrackType
track_type track parents
    | is_inst_track title = NoteTrack pitch_track
    | is_pitch_track title = PitchTrack
    | otherwise = ControlTrack
    where
    title = State.track_title track
    pitch_track = case List.find (is_pitch_track . State.track_title) parents of
        Nothing -> NoteTrack.PitchTrack True (State.track_tracknum track + 1)
        Just ptrack -> NoteTrack.PitchTrack False (State.track_tracknum ptrack)


-- ** compile

-- | A schema is split into two parts: parse the tracks into a skeleton, and
-- then convert the skeleton into a deriver.  The intermediate data structure
-- allows me to compose schemas out of smaller parts, as well as inspect the
-- skeleton for e.g. instrument tracks named, or to create a view layout.
default_schema_deriver :: SchemaDeriver Derive.EventDeriver
default_schema_deriver block_id =
    fmap compile (State.get_track_tree block_id)

default_schema_signal_deriver :: SchemaDeriver Derive.SignalDeriver
default_schema_signal_deriver block_id =
    fmap compile_to_signals (State.get_track_tree block_id)

-- | Transform a deriver skeleton into a real deriver.  The deriver may throw
-- if the skeleton was malformed.
compile :: State.TrackTree -> Derive.EventDeriver
compile tree = Derive.with_msg "compile" $
    Derive.d_merge =<< mapM _compile tree
_compile :: Tree.Tree State.TrackInfo -> Derive.EventDeriver
_compile (Tree.Node track@(State.TrackInfo title track_id _) subs)
    | is_inst_track title = if not (null subs)
        then Derive.throw $ "inst track " ++ show track ++ " has sub tracks "
            ++ show subs
        else Derive.with_track_warp Note.d_note_track track_id
    | otherwise = do
        when (null subs) $
            Log.warn $ "controller " ++ show track ++ " has no sub tracks"
        compile_controller title track_id
            (Derive.d_merge =<< mapM _compile subs)

compile_controller :: String -> Track.TrackId
    -> Derive.EventDeriver -> Derive.EventDeriver
compile_controller title track_id subderiver
    | is_tempo_track title = do
        -- A tempo track is derived like other signals, but gets special
        -- treatment because of the track warps chicanery.
        sig_events <- Derive.with_track_warp_tempo
            Controller.d_controller_track track_id
        Derive.d_tempo track_id (Controller.d_signal sig_events) subderiver
    | otherwise = do
        sig_events <- Derive.with_track_warp
            Controller.d_controller_track track_id
        -- TODO default to inst scale if none is given
        let signal = if is_pitch_track title
                then Controller.d_pitch_signal (scale_of_track title) sig_events
                else Controller.d_signal sig_events
        Controller.d_controller (Score.Controller title) signal subderiver


-- | Compile a Skeleton to its SignalDeriver.  The SignalDeriver is like the
-- main Deriver except that it derives down to track signals instead of events.
-- While the events go on to performance, the track signals go to the UI so
-- it can draw pretty graphs.
--
-- TODO Think about this some more in light of more complicated derivers.  It
-- seems annoying to have to make a whole separate signal deriver.  Getting the
-- signals from the track could be more hardcoded and less work when writing
-- a new schema.
compile_to_signals :: State.TrackTree -> Derive.SignalDeriver
compile_to_signals tree = Derive.with_msg "compile_to_signals" $
    Derive.d_signal_merge =<< mapM _compile_to_signals tree

_compile_to_signals :: Tree.Tree State.TrackInfo -> Derive.SignalDeriver
_compile_to_signals (Tree.Node (State.TrackInfo title track_id _) subs)
    | is_inst_track title = return []
    | otherwise = do
        -- Note no special treatment for tempo, since signal output shouldn't
        -- be warped.
        track_sigs <- signal_controller title track_id
        rest_sigs <- Derive.d_signal_merge =<< mapM _compile_to_signals subs
        return (track_sigs : rest_sigs)

signal_controller :: (Monad m) => String -> Track.TrackId
    -> Derive.DeriveT m (Track.TrackId, Signal.Signal)
signal_controller title track_id = do
    sig_events <- Derive.with_track_warp Controller.d_controller_track track_id
    sig <- if is_pitch_track title
        then Controller.d_pitch_signal (scale_of_track title) sig_events
        else Controller.d_signal sig_events
    return (track_id, sig)

-- ** track title

-- | The type of a track is derived from its title.
is_tempo_track, is_pitch_track, is_inst_track :: String -> Bool
is_tempo_track = (=="tempo")

is_pitch_track = (pitch_track_prefix `List.isPrefixOf`)
scale_of_track = Pitch.ScaleId . Seq.strip . drop 1
track_of_scale :: Pitch.ScaleId -> String
track_of_scale (Pitch.ScaleId scale_id) = pitch_track_prefix ++ scale_id

pitch_track_prefix = "*"
-- | This means use the instrument scale.
default_scale = Pitch.ScaleId ""

is_inst_track = (">" `List.isPrefixOf`)
inst_of_track = Score.Instrument . Seq.strip . drop 1

-- | Convert a track title into its instrument.  This could be per-schema, but
-- I'm going to hardcode it for now and assume all schemas will do the same
-- thing.
title_to_instrument :: String -> Maybe Score.Instrument
title_to_instrument name
    | is_inst_track name = Just $ inst_of_track name
    | otherwise = Nothing

title_to_scale :: String -> Maybe Pitch.ScaleId
title_to_scale name
    | is_pitch_track name = Just $ scale_of_track name
    | otherwise = Nothing

-- | Convert from an instrument to the title of its instrument track.
instrument_to_title :: Score.Instrument -> String
instrument_to_title (Score.Instrument inst) = '>' : inst

-- * parser

-- | A parser figures out a skeleton based on track titles and position.
--
-- Tracks starting with '>' are instrument tracks, the rest are control tracks.
-- The control tracks scope over the next instrument track to the left.
-- A track titled \"tempo\" scopes over all tracks to its right.
--
-- This should take arguments to apply to instrument and control tracks.
--
-- TODO do something special with embedded rulers and dividers
default_parser :: [State.TrackInfo] -> Skeleton.Skeleton
default_parser = Skeleton.make
    . Util.Tree.edges . map (fmap State.track_tracknum) . parse_to_tree

-- | [c0 tempo1 i1 c1 tempo2 c2 i2 c3] ->
-- [c0, tempo1 (c1 . i1), tempo2 (c2 . c3 . i2)]
parse_to_tree :: [State.TrackInfo] -> Tree.Forest State.TrackInfo
parse_to_tree tracks = concatMap parse_tempo_group $
    Seq.split_with (is_tempo_track . State.track_title) tracks

parse_tempo_group :: [State.TrackInfo] -> Tree.Forest State.TrackInfo
parse_tempo_group [] = []
parse_tempo_group (track:tracks)
    | is_tempo_track (State.track_title track) =
        [Tree.Node track (parse_inst_groups tracks)]
    | otherwise = parse_inst_groups (track:tracks)

-- | [c1 i1 c2 c3] -> c1 . c3 . c2 . i1
parse_inst_groups :: [State.TrackInfo] -> Tree.Forest State.TrackInfo
parse_inst_groups tracks = case inst_groups of
        [] -> []
        global : rest -> descend (concatMap parse_inst_group rest) global
    where
    inst_groups = Seq.split_with (is_inst_track . State.track_title) tracks

parse_inst_group :: [State.TrackInfo] -> Tree.Forest State.TrackInfo
parse_inst_group [] = []
parse_inst_group (track:tracks) = descend [Tree.Node track []] (reverse tracks)

descend :: Tree.Forest a -> [a] -> Tree.Forest a
descend bottom [] = bottom
descend bottom (track:tracks) = [Tree.Node track (descend bottom tracks)]
