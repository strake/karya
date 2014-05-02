-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE CPP #-}
{- | Derivers for control tracks.  That means tempo, control, and pitch.

    Control tracks (specifically control tracks, not tempo or pitch) can have
    a combining operator.  If no operator is given, they are combined with
    @mul@.  @set@ will replace the signal.  So two tracks named @c@ will
    multiply, same as if the second were @mul c@.  If you want to override @c@
    then @set c@ will do that.

    A control with a combining operator but nothing to combine with should still
    do something sensible because operators come with an identity value, e.g.
    @1@ for @mul@ and @0@ for @add@.

    Tempo tracks don't support operators because they are converted into
    a warp, which is then combined via composition.  Pitch tracks always
    replace each other because adding together absolute pitches is undefined.
    Relative pitches can be added or multiplied, and this is expressed via
    normal controls using transposition signals like 'Controls.chromatic'.
-}
module Derive.Control (
    d_control_track, split_control_tracks
    -- * TrackSignal
    , put_unwarped_signal, render_of
#ifdef TESTING
    , derive_control
#endif
) where
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Tree as Tree

import Util.Control
import qualified Util.Log as Log
import qualified Util.Seq as Seq

import qualified Ui.Block as Block
import qualified Ui.Event as Event
import qualified Ui.Events as Events
import qualified Ui.Track as Track
import qualified Ui.TrackTree as TrackTree

import qualified Derive.Cache as Cache
import qualified Derive.Call as Call
import qualified Derive.Call.Util as Util
import qualified Derive.Controls as Controls
import qualified Derive.Derive as Derive
import qualified Derive.Deriver.Internal as Internal
import qualified Derive.Environ as Environ
import qualified Derive.LEvent as LEvent
import qualified Derive.ParseTitle as ParseTitle
import qualified Derive.PitchSignal as PitchSignal
import qualified Derive.Scale as Scale
import qualified Derive.Score as Score
import qualified Derive.ShowVal as ShowVal
import qualified Derive.Tempo as Tempo
import qualified Derive.TrackLang as TrackLang

import qualified Perform.Pitch as Pitch
import qualified Perform.Signal as Signal
import Types


-- | Top level deriver for control tracks.
d_control_track :: TrackTree.EventsNode
    -> Derive.NoteDeriver -> Derive.NoteDeriver
d_control_track (Tree.Node track _) deriver = do
    let title = TrackTree.track_title track
    if Text.all Char.isSpace title then deriver else do
        (ctype, expr) <- either (\err -> Derive.throw $ "track title: " ++ err)
            return (ParseTitle.parse_control_expr title)
        eval_track track expr ctype deriver

-- | Preprocess a track tree by splitting the control tracks.  An event
-- starting with @%@ splits the events below it into a new control track.  The
-- text after the @%@ becomes the new track title.  Split tracks with the same
-- title will be merged together, but they have to have exactly the same title.
-- If they have different titles but create the same control, they will wind up
-- in separate tracks and likely the last one will win, due to the implicit
-- leading 0 sample in each control track.
--
-- Preprocessing at the track tree level means the split tracks act like real
-- tracks and interact with slicing correctly.
--
-- This is experimental.  It provides a way to have short ad-hoc control
-- sections, which is likely to be convenient for individual calls that can use
-- a control signal.  On the other hand, it invisibly rearranges the score, and
-- that has been a real mess with slicing.  Hopefully it's simple enough that
-- it won't be as confusing as slicing and inversion.
--
-- TrackSignals should work out because the split tracks all have the same
-- TrackId, and so their individual signal fragments should be joined as usual.
split_control_tracks :: TrackTree.EventsTree -> TrackTree.EventsTree
split_control_tracks = map split
    where
    split (Tree.Node track subs) =
        case ParseTitle.track_type (TrackTree.track_title track) of
            ParseTitle.ControlTrack -> splice (split_control track) subs
            _ -> Tree.Node track (map split subs)
        where
        splice [] subs = Tree.Node track subs
        splice [x] subs = Tree.Node x subs
        splice (x:xs) subs = Tree.Node x [splice xs subs]

-- | Look for events starting with @%@, and split the track at each one.
-- Each split-off track is titled with the text after the @%@.
split_control :: TrackTree.Track -> [TrackTree.Track]
split_control track = extract $ split $ TrackTree.track_events track
    where
    split events = go (TrackTree.track_title track) events $
        mapMaybe switch_control $ Events.ascending events
    go title events [] = [(title, events)]
    go title events ((start, next_title) : switches) =
        (title, pre) : go next_title post switches
        where (pre, post) = Events.split_at_exclude start events
    switch_control event
        | Just ('%', title) <- Text.uncons (Event.event_text event),
            not (Text.null title) = Just (Event.start event, title)
        | otherwise = Nothing
    extract [] = [track]
    extract [_] = [track]
    extract tracks = map convert (merge tracks)
    convert (title,  events) = track
        { TrackTree.track_title = title
        , TrackTree.track_events = events
        }
    -- Tracks with the same name are merged back together.
    -- TODO Group by control, not title.
    merge = map merge_track . Seq.group_on fst
    merge_track [] = error "Seq.group_on postcondition violated"
    merge_track tracks@((title, _) : _) = (title, mconcatMap snd tracks)

-- * eval_track

eval_track :: TrackTree.Track -> [TrackLang.Call]
    -> ParseTitle.ControlType -> Derive.NoteDeriver -> Derive.NoteDeriver
eval_track track expr ctype deriver = case ctype of
    ParseTitle.Tempo maybe_sym -> do
        is_ly <- Derive.is_lilypond_derive
        let sig_deriver
                | is_ly = return (Signal.constant 1, [])
                | otherwise = with_control_env Controls.tempo "compose" $
                    derive_control True track expr
        tempo_call maybe_sym track sig_deriver deriver
    ParseTitle.Control maybe_op control -> do
        let control_name = Score.typed_val control
        merge <- lookup_op control_name maybe_op
        control_call track control merge
            (with_control_env control_name (merge_name control_name merge)
                (derive_control False track expr))
            deriver
    ParseTitle.Pitch scale_id maybe_name ->
        pitch_call track maybe_name scale_id expr deriver

merge_name :: Score.Control -> Derive.Merge -> Text
merge_name control = maybe "set" name_of . Derive.merge_op control
    where name_of (Derive.ControlOp name _) = name

-- | Get the combining operator for this track.
--
-- 'Controls.null' is used by control calls, and uses 'Derive.Set' by default
-- instead of 'Derive.Default'.  Since the control call emits signal which then
-- goes in a control track, it would lead to multiplication being applied
-- twice.  In addition, applying a relative signal tends to create a leading
-- 0 sample, which then causes control calls to wipe out previous samples.
lookup_op :: Score.Control -> Maybe TrackLang.CallId
    -> Derive.Deriver Derive.Merge
lookup_op control op = case op of
    Nothing
        | control == Controls.null -> return Derive.Set
        | otherwise -> return Derive.Default
    Just sym
        | sym == "set" -> return Derive.Set
        | otherwise -> Derive.Merge <$> Derive.get_control_op sym

-- | A tempo track is derived like other signals, but in absolute time.
-- Otherwise it would wind up being composed with the environmental warp twice.
tempo_call :: Maybe TrackLang.Symbol -> TrackTree.Track
    -> Derive.Deriver (TrackResults Signal.Control)
    -> Derive.NoteDeriver -> Derive.NoteDeriver
tempo_call sym track sig_deriver deriver = do
    (signal, logs) <- Internal.in_real_time $ do
        (signal, logs) <- sig_deriver
        -- Do this in real time, so 'stash_if_wanted' knows it can directly
        -- reuse the signal.
        stash_if_wanted track signal
        return (signal, logs)

    -- 'with_damage' must be applied *inside* 'd_tempo'.  If it were outside,
    -- it would get the wrong RealTimes when it tried to create the
    -- ControlDamage.
    merge_logs logs $ dispatch_tempo sym (TrackTree.track_end track)
        maybe_track_id (Signal.coerce signal) (with_damage deriver)
    where
    maybe_block_track_id = TrackTree.track_block_track_id track
    maybe_track_id = snd <$> maybe_block_track_id
    with_damage = maybe id get_damage maybe_block_track_id
    get_damage (block_id, track_id) deriver = do
        damage <- Cache.get_tempo_damage block_id track_id
            (TrackTree.track_end track)
            (TrackTree.track_events track)
        Internal.with_control_damage damage deriver

dispatch_tempo :: Maybe TrackLang.Symbol -> ScoreTime -> Maybe TrackId
    -> Signal.Tempo -> Derive.Deriver a -> Derive.Deriver a
dispatch_tempo sym block_dur maybe_track_id signal deriver = case sym of
    Nothing -> Tempo.with_tempo block_dur maybe_track_id signal deriver
    Just sym
        | sym == "hybrid" ->
            Tempo.with_hybrid block_dur maybe_track_id signal deriver
        | sym == "abs" ->
            Tempo.with_absolute block_dur maybe_track_id signal deriver
        | otherwise -> Derive.throw $
            "unknown tempo modifier: " <> untxt (ShowVal.show_val sym)

control_call :: TrackTree.Track -> Score.Typed Score.Control
    -> Derive.Merge -> (Derive.Deriver (TrackResults Signal.Control))
    -> Derive.NoteDeriver -> Derive.NoteDeriver
control_call track control merge control_deriver deriver = do
    (signal, logs) <- Internal.track_setup track control_deriver
    stash_if_wanted track signal
    -- Apply and strip any control modifications made during the above derive.
    Derive.apply_control_mods $ merge_logs logs $ with_damage $
        with_control_op control merge signal deriver
    -- I think this forces sequentialness because 'deriver' runs in the state
    -- from the end of 'control_deriver'.  To make these parallelize, I need to
    -- run control_deriver as a sub-derive, then mappend the Collect.
    where
    with_damage = with_control_damage
        (TrackTree.track_block_track_id track) (TrackTree.track_range track)

with_control_op :: Score.Typed Score.Control -> Derive.Merge -> Signal.Control
    -> Derive.Deriver a -> Derive.Deriver a
with_control_op (Score.Typed typ control) merge signal =
    Derive.with_merged_control merge control (Score.Typed typ signal)

merge_logs :: [Log.Msg] -> Derive.NoteDeriver -> Derive.NoteDeriver
merge_logs logs deriver = do
    events <- deriver
    return $ Derive.merge_events (map LEvent.Log logs) events

pitch_call :: TrackTree.Track -> Maybe Score.Control -> Pitch.ScaleId
    -> [TrackLang.Call] -> Derive.NoteDeriver -> Derive.NoteDeriver
pitch_call track maybe_name scale_id expr deriver =
    Internal.track_setup track $ do
        scale <- get_scale scale_id
        Derive.with_scale scale $ do
            (signal, logs) <- derive_pitch True track expr
            -- Ignore errors, they should be logged on conversion.
            (nn_sig, _) <- pitch_signal_to_nn signal
            stash_if_wanted track (Signal.coerce nn_sig)
            -- Apply and strip any control modifications made during the above
            -- derive.
            Derive.apply_control_mods $ merge_logs logs $ with_damage $
                Derive.with_pitch maybe_name signal deriver
    where
    with_damage = with_control_damage (TrackTree.track_block_track_id track)
        (TrackTree.track_range track)

get_scale :: Pitch.ScaleId -> Derive.Deriver Scale.Scale
get_scale scale_id
    | scale_id == Pitch.empty_scale = Util.get_scale
    | otherwise = Derive.get_scale scale_id

with_control_damage :: Maybe (BlockId, TrackId) -> (TrackTime, TrackTime)
    -> Derive.Deriver d -> Derive.Deriver d
with_control_damage maybe_block_track_id track_range =
    maybe id get_damage maybe_block_track_id
    where
    get_damage (block_id, track_id) deriver = do
        damage <- Cache.get_control_damage block_id track_id track_range
        Internal.with_control_damage damage deriver


-- | Split the signal chunks and log msgs of the 'LEvent.LEvents' stream.
-- Return signal chunks merged into a signal, the logs cast to Score.Event
-- logs.
type TrackResults sig = (sig, [Log.Msg])

-- | Derive the signal of a control track.
derive_control :: Bool -> TrackTree.Track -> [TrackLang.Call]
    -> Derive.Deriver (TrackResults Signal.Control)
derive_control is_tempo track expr = do
    let name = if is_tempo then "tempo track" else "control track"
    stream <- Call.apply_transformers (track_call_info track name) expr deriver
    let (signal_chunks, logs) = LEvent.partition stream
        -- I just did it in 'compact', so this should just convert [x] to x.
        signal = mconcat signal_chunks
    real_end <- Derive.real (TrackTree.track_end track)
    return (extend real_end signal, logs)
    where
    deriver :: Derive.ControlDeriver
    deriver = Cache.track track mempty $ do
        state <- Derive.get
        let (stream, collect) = Call.derive_control_track state tinfo
                Call.control_last_sample (track_events track)
        Internal.merge_collect collect
        return $ compact (concat stream)
    -- Merge the signal here so it goes in the cache as one signal event.
    -- I can use concat instead of merge_asc_events because the signals
    -- will be merged with Signal.merge and the logs extracted.
    compact events = LEvent.Event (mconcat sigs) : map LEvent.Log logs
        where (sigs, logs) = LEvent.partition events
    tinfo = Call.TrackInfo
        { Call.tinfo_track = track
        , Call.tinfo_sub_tracks = []
        , Call.tinfo_type =
            if is_tempo then ParseTitle.TempoTrack else ParseTitle.ControlTrack
        }
    extend end
        | is_tempo = Signal.coerce . Tempo.extend_signal end . Signal.coerce
        | otherwise = id

derive_pitch :: Bool -> TrackTree.Track -> [TrackLang.Call]
    -> Derive.Deriver (TrackResults PitchSignal.Signal)
derive_pitch cache track expr = do
    stream <- Call.apply_transformers (track_call_info track "pitch track")
        expr deriver
    let (signal_chunks, logs) = LEvent.partition stream
        -- I just did it in 'compact', so this should just convert [x] to x.
        signal = mconcat signal_chunks
    return (signal, logs)
    where
    deriver = (if cache then Cache.track track mempty else id) $ do
        state <- Derive.get
        let (stream, collect) = Call.derive_control_track state tinfo
                Call.pitch_last_sample (track_events track)
        Internal.merge_collect collect
        return $ compact (concat stream)
    -- Merge the signal here so it goes in the cache as one signal event.
    compact events = LEvent.Event (mconcat sigs) : map LEvent.Log logs
        where (sigs, logs) = LEvent.partition events
    tinfo = Call.TrackInfo
        { Call.tinfo_track = track
        , Call.tinfo_sub_tracks = []
        , Call.tinfo_type = ParseTitle.PitchTrack
        }

track_events :: TrackTree.Track -> [Event.Event]
track_events = Events.ascending . TrackTree.track_events

-- | Create a CallInfo for the title call of a track.
track_call_info :: TrackTree.Track -> Text -> Derive.CallInfo d
track_call_info track name =
    Derive.dummy_call_info 0 (TrackTree.track_end track) name

-- * TrackSignal

-- | If this track is to be rendered by the UI, stash the given signal as
-- in either 'Derive.collect_track_signals' or
-- 'Derive.collect_signal_fragments'.
stash_if_wanted :: TrackTree.Track -> Signal.Control -> Derive.Deriver ()
stash_if_wanted track sig =
    whenJustM (render_of track) $ \(block_id, track_id, _) ->
        if TrackTree.track_sliced track
            then put_signal_fragment block_id track_id sig
            else put_unwarped_signal block_id track_id sig

put_signal_fragment :: BlockId -> TrackId -> Signal.Control -> Derive.Deriver ()
put_signal_fragment block_id track_id sig = Internal.modify_collect $
    -- TODO profile with Internal.merge_collect
    \collect -> collect { Derive.collect_signal_fragments =
        add (Derive.collect_signal_fragments collect) }
    where
    -- See 'Derive.SignalFragment' for the expected (lack of) order.
    add = Map.alter (maybe (Just [sig]) (Just . (sig:))) (block_id, track_id)

put_unwarped_signal :: BlockId -> TrackId -> Signal.Control -> Derive.Deriver ()
put_unwarped_signal block_id track_id sig = do
    warp <- Internal.get_dynamic Derive.state_warp
    put_track_signal block_id track_id (Call.unwarp warp sig)

put_track_signal :: BlockId -> TrackId -> Track.TrackSignal -> Derive.Deriver ()
put_track_signal block_id track_id tsig = Internal.merge_collect $ mempty
    { Derive.collect_track_signals = Map.singleton (block_id, track_id) tsig }

-- | Get render information if this track wants a TrackSignal.
render_of :: TrackTree.Track
    -> Derive.Deriver (Maybe (BlockId, TrackId, Maybe Track.RenderSource))
render_of track = case TrackTree.track_block_track_id track of
    Nothing -> return Nothing
    Just (block_id, track_id) -> do
        (btrack, track) <- get_block_track block_id track_id
        let flags = Block.track_flags btrack
        return $ if Block.wants_track_signal flags track
            then Just (block_id, track_id,
                extract (Track.render_style (Track.track_render track)))
            else Nothing
    where
    extract (Track.Line (Just source)) = Just source
    extract (Track.Filled (Just source)) = Just source
    extract _ = Nothing

get_block_track :: BlockId -> TrackId
    -> Derive.Deriver (Block.Track, Track.Track)
get_block_track block_id track_id = do
    track <- Derive.get_track track_id
    block <- Derive.get_block block_id
    btrack <- Derive.require
        ("get_block_track: " <> show block_id <> " doesn't have "
            <> show track_id) $
        List.find ((== Just track_id) . Block.track_id)
            (Block.block_tracks block)
    return (btrack, track)


-- * util

-- | Reduce a 'PitchSignal.Signal' to raw note numbers, taking the current
-- transposition environment into account.
pitch_signal_to_nn :: PitchSignal.Signal
    -> Derive.Deriver (Signal.NoteNumber, [PitchSignal.PitchError])
pitch_signal_to_nn sig = do
    controls <- Internal.get_dynamic Derive.state_controls
    environ <- Internal.get_environ
    return $ PitchSignal.to_nn $ PitchSignal.apply_controls environ controls sig

with_control_env :: Score.Control -> Text -> Derive.Deriver a
    -> Derive.Deriver a
with_control_env control merge =
    Derive.with_val Environ.control (Score.control_name control)
    . Derive.with_val Environ.merge merge
