-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE FlexibleContexts #-}
{- | Carnatic style pitch ornaments.

    The names don't correspond directly with anything traditional, as far as
    I know, but are inspired by <http://www.gswift.com/article-2.html>.

    Pitch ornaments can be expressed either as pitch calls, or as control
    calls meant for a transpose track.  They both have pros and cons:

    Transposition control signal:

    - I can keep the pitches separate and clear and collapse the pitch
    track.  This correctly reflects the underlying sargam, with the gamakam
    as separate ornamentation.

    - Related to the above, each call doesn't need to repeat the the pitch arg,
    so there's less redundancy.  Calls are also simpler with one fewer
    argument.

    Pitch signal:

    - A pitch call can use absolute (@t-nn@) or scalar (@t-diatonic@)
    transposition based on the type of its arguments, while the transpose
    signal has to either use a separate track, or the somewhat awkward @->@
    call.

    - The pitch signal can represent an ornament involving multiple pitches,
    e.g. a slide frome one pitch to another.  A transposition signal can only
    represent offsets from an external pitch.

    So the pitch signal is more powerful, but the transposition signal is often
    more convenient, and can lead to less redundant notation.  Unless I can
    think of a way to get the advantages of both, I might have to have both
    around, with their own versions of the same calls.
-}
module Derive.Call.India.Gamakam where
import qualified Data.List.NonEmpty as NonEmpty

import Util.Control
import qualified Util.Num as Num
import qualified Util.Seq as Seq

import qualified Derive.Args as Args
import qualified Derive.Call.Control as Control
import qualified Derive.Call.Europe.Trill as Trill
import qualified Derive.Call.Make as Make
import qualified Derive.Call.SignalTransform as SignalTransform
import qualified Derive.Call.Tags as Tags
import qualified Derive.Call.Util as Util
import qualified Derive.Controls as Controls
import qualified Derive.Derive as Derive
import qualified Derive.Environ as Environ
import qualified Derive.PitchSignal as PitchSignal
import qualified Derive.Score as Score
import qualified Derive.ShowVal as ShowVal
import qualified Derive.Sig as Sig
import Derive.Sig (defaulted, defaulted_env, required)
import qualified Derive.TrackLang as TrackLang

import qualified Perform.RealTime as RealTime
import qualified Perform.Signal as Signal
import Types


pitch_calls :: Derive.CallMaps Derive.Pitch
pitch_calls = Derive.call_maps
    ([("dip", c_dip)
    , ("jaru", c_jaru)
    , ("sgr", c_jaru_intervals Util.Diatonic [-1, 1])
    ] ++ kampita_variations "kam" c_kampita)
    [ ("h", c_hold)
    ]

control_calls :: Derive.CallMaps Derive.Control
control_calls = Derive.call_maps gs ts
    where
    gs =
        [ ("dip", c_dip_c)
        , ("j)", jaru_transition_c "j)" Nothing
            "Time for each slide, defaults to `time`.")
        , ("j]", jaru_transition_c "j]" (Just (jaru_time_default / 2))
            "Time for each slide.")
        , ("sgr", c_jaru_intervals_c [-1, 1])
        ] ++ kampita_variations "kam" c_kampita_c
        ++ kampita_variations "nkam" c_nkampita_c
    ts =
        [ ("h", c_hold)
        ]

kampita_variations :: Text -> (Maybe Mode -> Maybe Mode -> call)
    -> [(TrackLang.CallId, call)]
kampita_variations name call =
    [ (TrackLang.Symbol $ mode_affix s <> name <> mode_affix e, call s e)
    | s <- modes, e <- modes
    ]
    where
    modes = [Nothing, Just Low, Just High]

mode_affix :: Maybe Mode -> Text
mode_affix Nothing = ""
mode_affix (Just High) = "^"
mode_affix (Just Low) = "_"

data Mode = High | Low deriving (Eq, Show)

c_hold :: Derive.ToTagged (Derive.Elem d) => Derive.Transformer d
c_hold = Make.with_environ "hold"
    (defaulted "time" (TrackLang.real 1) "Hold first value for this long.")
    TrackLang.default_real

-- * standard parameters

transition_default :: RealTime
transition_default = 0.08

jaru_time_default :: RealTime
jaru_time_default = 0.15

speed_arg :: Sig.Parser TrackLang.ValControl
speed_arg = defaulted "speed" (Sig.typed_control "trill-speed" 6 Score.Real)
    "Alternate pitches at this speed."

neighbor_arg :: Sig.Parser TrackLang.ValControl
neighbor_arg = defaulted "neighbor"
    (Sig.typed_control "trill-neighbor" 1 Score.Untyped)
    "Alternate between 0 and this value."

lilt_env :: Sig.Parser Double
lilt_env = Sig.environ "lilt" Sig.Both 0 "Lilt is a horizontal bias to the\
    \ vibrato. A lilt of 1 would place each neighbor on top of the\
    \ following unison, while -1 would place it on the previous one.\
    \ So it should range from -1 < lilt < 1."

hold_env :: Sig.Parser TrackLang.DefaultReal
hold_env = Sig.environ (TrackLang.unsym Environ.hold) Sig.Unprefixed
    (TrackLang.real 0) "Time to hold the first pitch."

adjust_env :: Sig.Parser AdjustMode
adjust_env = TrackLang.get_e <$>
    Sig.environ "adjust" Sig.Unprefixed (TrackLang.E Shorten)
    "How to adjust an ornament to fulfill its mode restrictions."

-- | How to adjust an ornament to fulfill its 'Mode' restrictions.
data AdjustMode =
    -- | Adjust by shortening the ornament.
    Shorten
    -- | Adjust by increasing the speed.
    | Stretch
    deriving (Bounded, Eq, Enum, Show)

instance ShowVal.ShowVal AdjustMode where show_val = TrackLang.default_show_val
instance TrackLang.TypecheckEnum AdjustMode

-- * pitch calls

c_kampita :: Maybe Mode -> Maybe Mode -> Derive.Generator Derive.Pitch
c_kampita start_mode end_mode = Derive.generator1 "kam" Tags.india
    "This is a kind of trill, but its interval defaults to NNs,\
    \ and transitions between the notes are smooth.  It's intended for\
    \ the vocal microtonal trills common in Carnatic music."
    $ Sig.call ((,,,,,,)
    <$> required "pitch" "Base pitch."
    <*> defaulted "neighbor" (Sig.typed_control "trill-neighbor" 1 Score.Nn)
        "Alternate with a pitch at this interval."
    <*> speed_arg
    <*> defaulted_env "transition" Sig.Both transition_default
        "Time for each slide."
    <*> hold_env <*> lilt_env <*> adjust_env
    ) $ \(pitch, neighbor, speed, transition, hold, lilt, adjust) args -> do
        (neighbor, control) <- Util.to_transpose_function Util.Nn neighbor
        transpose <- kampita start_mode end_mode adjust neighbor speed
            transition hold lilt args
        start <- Args.real_start args
        return $ PitchSignal.apply_control control
            (Score.untyped transpose) $ PitchSignal.signal [(start, pitch)]

trill_transitions :: Maybe Bool -> AdjustMode -> Double -> ScoreTime
    -> TrackLang.ValControl -> (ScoreTime, ScoreTime)
    -> Derive.Deriver [RealTime]
trill_transitions even adjust lilt hold speed (start, end) = do
    real_end <- Derive.real end
    add_hold . add_lilt lilt . adjust_transitions real_end adjust . trim
        =<< Trill.trill_transitions (start + hold, end) include_end speed
    where
    -- Trills usually omit the transition that coincides with the end because
    -- that would create a zero duration note.  But these trills are smoothed
    -- and thus will still have a segment leading to the cut-off transition.
    include_end = True
    add_hold transitions
        | hold > 0 = (: drop 1 transitions) <$> Derive.real start
        | otherwise = return transitions
    trim = case even of
        Nothing -> id
        Just even -> if even then take_even else take_odd
    take_even (x:y:zs) = x : y : take_even zs
    take_even _ = []
    take_odd [x, _] = [x]
    take_odd (x:y:zs) = x : y : take_odd zs
    take_odd xs = xs

adjust_transitions :: RealTime -> AdjustMode -> [RealTime] -> [RealTime]
adjust_transitions _ Shorten ts = ts
adjust_transitions end Stretch ts@(_:_:_) = zipWith (+) offsets ts
    where
    -- (_:_:_) above means both the last and division are safe.
    stretch = max 0 (end - last ts) / fromIntegral (length ts - 1)
    offsets = Seq.range_ 0 stretch
adjust_transitions _ Stretch ts = ts

add_lilt :: Double -> [RealTime] -> [RealTime]
add_lilt _ [] = []
add_lilt lilt (t:ts)
    | lilt == 0 = t : ts
    | lilt > 0 = t : positive (min 1 (RealTime.seconds lilt)) ts
    | otherwise = negative (min 1 (RealTime.seconds (abs lilt))) (t:ts)
    where
    positive lilt (x:y:zs) = Num.scale x y lilt : y : positive lilt zs
    positive _ xs = xs
    negative lilt (x:y:zs) = x : Num.scale x y lilt : negative lilt zs
    negative _ xs = xs


-- | Make a trill signal from a list of transition times.
trill_from_transitions :: Util.Function -> Util.Function
    -> [RealTime] -> Signal.Control
trill_from_transitions val1 val2 transitions = Signal.signal
    [(x, sig x) | (x, sig) <- zip transitions (cycle [val1, val2])]

-- | Ok, this name is terrible but what else is better?
c_dip :: Derive.Generator Derive.Pitch
c_dip = Derive.generator1 "dip" Tags.india
    "Alternate two intervals, dropping `dyn` on the second. This is useful\
    \ when avoiding a swaram, since it doesn't necessarily emit the base\
    \ pitch."
    $ Sig.call ((,,,,,)
    <$> required "pitch" "Base pitch."
    <*> defaulted "high" (TrackLang.diatonic 1) "High interval."
    <*> defaulted "low" (-1) "Low interval."
    <*> speed_arg
    <*> defaulted "dyn" 0.5 "Multiply dyn by this amount."
    <*> Sig.environ "transition" Sig.Both transition_default
        "Time for each slide."
    ) $ \(pitch, TrackLang.DefaultDiatonic high_, low, speed, dyn_scale,
            transition) args -> do
        let (high, control) = Controls.transpose_control high_
        transpose <- dip high low speed dyn_scale transition
            (Args.range_or_next args)
        start <- Args.real_start args
        return $ PitchSignal.apply_control control
            (Score.untyped transpose) $ PitchSignal.signal [(start, pitch)]

c_jaru :: Derive.Generator Derive.Pitch
c_jaru = Derive.generator1 "jaru" Tags.india
    "This is a series of grace notes whose pitches are relative to the given\
    \ base pitch."
    $ Sig.call ((,,,)
    <$> required "pitch" "Base pitch."
    <*> Sig.many1 "interval" "Intervals from base pitch."
    <*> Sig.environ "time" Sig.Both jaru_time_default "Time for each note."
    <*> Sig.environ "transition" Sig.Both Nothing
        "Time for each slide, defaults to `time`."
    ) $ \(pitch, intervals, time, maybe_transition) args -> do
        start <- Args.real_start args
        srate <- Util.get_srate
        (intervals, control) <- parse intervals
        let transition = fromMaybe time maybe_transition
        let sig = jaru srate start time transition (NonEmpty.toList intervals)
        return $ PitchSignal.apply_control control
            (Score.untyped sig) $ PitchSignal.signal [(start, pitch)]
    where
    parse intervals
        | all (==control) controls = return (xs, control)
        | otherwise = Derive.throw "all intervals must have the same type"
        where
        (xs, control :| controls) = NonEmpty.unzip $ NonEmpty.map
            (Controls.transpose_control . TrackLang.default_diatonic)
            intervals

c_jaru_intervals :: Util.TransposeType -> [Signal.Y]
    -> Derive.Generator Derive.Pitch
c_jaru_intervals transpose intervals = Derive.generator1 "jaru" Tags.india
    ("This is `jaru` hardcoded to " <> prettyt intervals <> ".")
    $ Sig.call ((,,)
    <$> required "pitch" "Base pitch."
    <*> defaulted "time" jaru_time_default "Time for each note."
    <*> defaulted "transition" Nothing
        "Time for each slide, defaults to `time`."
    ) $ \(pitch, time, maybe_transition) args -> do
        start <- Args.real_start args
        srate <- Util.get_srate
        let sig = jaru srate start time (fromMaybe time maybe_transition)
                intervals
        return $ PitchSignal.apply_control (Util.transpose_control transpose)
            (Score.untyped sig) $ PitchSignal.signal [(start, pitch)]


-- * control calls

-- | I had a lot of debate about whether I should use High and Low, or Unison
-- and Neighbor.  Unison-Neighbor is more convenient for the implementation
-- but High-Low I think is more musically intuitive.
c_kampita_c :: Maybe Mode -> Maybe Mode -> Derive.Generator Derive.Control
c_kampita_c start_mode end_mode = Derive.generator1 "kam" Tags.india
    "This is a trill with smooth transitions between the notes.  It's intended\
    \ for the vocal microtonal trills common in Carnatic music.\
    \ `^` is high and `_` is low, so `^kam_` starts on the upper note, and\
    \ ends on the lower one. Otherwise, it starts on the unison note and ends\
    \ on either. It determines the end note by shortening the trill if\
    \ necessary."
    $ Sig.call ((,,,,,)
    <$> neighbor_arg
    <*> speed_arg
    <*> defaulted_env "transition" Sig.Both transition_default
        "Time for each slide."
    <*> hold_env <*> lilt_env <*> adjust_env
    ) $ \(neighbor, speed, transition, hold, lilt, adjust) args -> do
        neighbor <- Util.to_function neighbor
        kampita start_mode end_mode adjust neighbor speed transition hold lilt
            args

-- | You don't think there are too many arguments, do you?
kampita :: Maybe Mode -> Maybe Mode -> AdjustMode -> Util.Function
    -> TrackLang.ValControl -> RealTime -> TrackLang.DefaultReal
    -> Double -> Derive.PassedArgs a -> Derive.Deriver Signal.Control
kampita start_mode end_mode adjust neighbor speed transition
        (TrackLang.DefaultReal hold) lilt args = do
    start <- Args.real_start args
    let ((val1, val2), even_transitions) = convert_modes start neighbor
            start_mode end_mode
    hold <- Util.score_duration (Args.start args) hold
    smooth_trill (-transition) val1 val2
        =<< trill_transitions even_transitions adjust lilt hold speed
            (Args.range_or_next args)

smooth_trill :: RealTime -> Util.Function -> Util.Function
    -> [RealTime] -> Derive.Deriver Signal.Control
smooth_trill time val1 val2 transitions = do
    srate <- Util.get_srate
    return $ SignalTransform.smooth id srate time $
        trill_from_transitions val1 val2 transitions

convert_modes :: RealTime -> Util.Function -> Maybe Mode -> Maybe Mode
    -> ((Util.Function, Util.Function), Maybe Bool)
convert_modes start_t neighbor start end = (vals, even_transitions)
    where
    first = case start of
        Nothing -> Trill.Unison
        Just Low -> if neighbor_low then Trill.Neighbor else Trill.Unison
        Just High -> if neighbor_low then Trill.Unison else Trill.Neighbor
    vals = case first of
        Trill.Unison -> (const 0, neighbor)
        Trill.Neighbor -> (neighbor, const 0)
    -- If I end Low, and neighbor is low, and I started with Unison, then val2
    -- is low, so I want even transitions.  Why is it so complicated just to
    -- get a trill to end high or low?
    first_low = case first of
        Trill.Unison -> not neighbor_low
        Trill.Neighbor -> neighbor_low
    even_transitions = case end of
        Nothing -> Nothing
        Just Low -> Just (not first_low)
        Just High -> Just first_low
    neighbor_low = neighbor start_t < 0

c_nkampita_c :: Maybe Mode -> Maybe Mode -> Derive.Generator Derive.Control
c_nkampita_c start_mode end_mode = Derive.generator1 "nkam" Tags.india
    "`kam` with a set number of cycles. The speed adjusts to fit the cycles in\
    \ before the next event."
    $ Sig.call ((,,,,)
    <$> neighbor_arg
    <*> defaulted "cycles" (TrackLang.Positive 1) "Number of cycles."
    <*> lilt_env <*> hold_env
    <*> Sig.environ "transition" Sig.Both transition_default
        "Time for each slide."
    ) $ \(neighbor, TrackLang.Positive cycles, lilt, TrackLang.DefaultReal hold,
            transition) args -> do
        (start, end) <- Args.real_range_or_next args
        neighbor <- Util.to_function neighbor
        let ((val1, val2), even_transitions) = convert_modes start neighbor
                start_mode end_mode
        hold <- Util.score_duration (Args.start args) hold
        -- In order to hear the cycles clearly, I leave a one transition of
        -- flat space at the end.  This means nkam can't transition into the
        -- next note, but for now this seems more convenient.
        let num_transitions = 1 + cycles * 2
                + (if even_transitions == Just True then 0 else 1)
        let speed = TrackLang.constant_control $
                (num_transitions - 1) / RealTime.to_seconds (end - start)
        transitions <- trill_transitions Nothing Shorten lilt hold speed
                (Args.range_or_next args)
        smooth_trill (-transition) val1 val2 (Seq.rdrop 1 transitions)

-- | Ok, this name is terrible but what else is better?
c_dip_c :: Derive.Generator Derive.Control
c_dip_c = Derive.generator1 "dip" Tags.india
    "Alternate two intervals, dropping `dyn` on the second. This is useful\
    \ when avoiding a swaram, since it doesn't necessarily emit the base\
    \ pitch."
    $ Sig.call ((,,,,)
    <$> defaulted "high" 1 "High interval."
    <*> defaulted "low" (-1) "Low interval."
    <*> speed_arg
    <*> defaulted "dyn" 0.5 "Multiply dyn by this amount."
    <*> Sig.environ "transition" Sig.Both transition_default
        "Time for each slide."
    ) $ \(high, low, speed, dyn_scale, transition) args ->
        dip high low speed dyn_scale transition (Args.range_or_next args)

dip :: Double -> Double -> TrackLang.ValControl -> Double
    -> RealTime -> (ScoreTime, ScoreTime) -> Derive.Deriver Signal.Control
dip high low speed dyn_scale transition (start, end) = do
    srate <- Util.get_srate
    transitions <- Trill.trill_transitions (start, end) False speed
    let smooth = SignalTransform.smooth id srate (-transition / 2)
        transpose = smooth $
            trill_from_transitions (const high) (const low) transitions
        dyn = smooth $
            trill_from_transitions (const 1) (const dyn_scale) transitions
    end <- Derive.real end
    Control.multiply_dyn end dyn
    return transpose

jaru_transition_c :: Text -> Maybe RealTime -> Text
    -> Derive.Generator Derive.Control
jaru_transition_c name default_transition transition_doc =
    Derive.generator1 name Tags.india
    "This is a series of grace notes with relative pitches."
    $ Sig.call ((,,)
    <$> Sig.many1 "interval" "Intervals from base pitch."
    <*> Sig.environ "time" Sig.Both jaru_time_default "Time for each note."
    <*> Sig.environ "transition" Sig.Both default_transition transition_doc
    ) $ \(intervals, time, maybe_transition) args -> do
        start <- Args.real_start args
        srate <- Util.get_srate
        let transition = fromMaybe time maybe_transition
        return $ jaru srate start time transition (NonEmpty.toList intervals)

c_jaru_intervals_c :: [Signal.Y] -> Derive.Generator Derive.Control
c_jaru_intervals_c intervals = Derive.generator1 "jaru" Tags.india
    ("This is `jaru` hardcoded to " <> prettyt intervals <> ".")
    $ Sig.call ((,)
    <$> defaulted "time" jaru_time_default "Time for each note."
    <*> defaulted "transition" Nothing
        "Time for each slide, defaults to `time`."
    ) $ \(time, maybe_transition) args -> do
        start <- Args.real_start args
        srate <- Util.get_srate
        return $ jaru srate start time (fromMaybe time maybe_transition)
            intervals

jaru :: RealTime -> RealTime -> RealTime -> RealTime -> [Signal.Y]
    -> Signal.Control
jaru srate start time transition intervals =
    SignalTransform.smooth id srate (-transition) $
        Signal.signal (zip (Seq.range_ start time) (intervals ++ [0]))