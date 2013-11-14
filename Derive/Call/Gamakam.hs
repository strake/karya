-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Carnatic style pitch ornaments.
--
-- The names don't correspond directly with anything traditional, as far as
-- I know, but are inspired by <http://www.gswift.com/article-2.html>.
module Derive.Call.Gamakam where
import qualified Data.List.NonEmpty as NonEmpty

import Util.Control
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq

import qualified Derive.Args as Args
import qualified Derive.Call.SignalTransform as SignalTransform
import qualified Derive.Call.Tags as Tags
import qualified Derive.Call.Trill as Trill
import qualified Derive.Call.Util as Util
import qualified Derive.Controls as Controls
import qualified Derive.Derive as Derive
import qualified Derive.PitchSignal as PitchSignal
import qualified Derive.Score as Score
import qualified Derive.Sig as Sig
import Derive.Sig (defaulted, required)
import qualified Derive.TrackLang as TrackLang

import qualified Perform.Signal as Signal
import Types

pitch_calls :: Derive.CallMaps Derive.Pitch
pitch_calls = Derive.call_maps
    [ ("kam", c_kampita Trill.UnisonFirst)
    , ("kam^", c_kampita Trill.NeighborFirst)
    , ("jaru", c_jaru)
    , ("sgr", c_jaru_intervals Util.Diatonic [-1, 1])
    ]
    []

-- TODO note version that ends on up or down
-- variations:
-- start high or low
-- end high or low - For this I need to know how when the note ends.  It can
-- either adjust the speed of the trill, or adjust the length of the note.
--
-- It seems like it might be nice to have ornaments be able to adjust tempo,
-- otherwise you have to coordinate changes in the tempo track.  But you can't
-- do it if you don't want it to affect other instruments.
--
-- To lengthen the note, it's actually in a position to do that since it's
-- above the note.  It could set a value which the note call will use for the
-- end, like an absolute duration sustain.  But it needs to know what it
-- originally was to round up, which requires peeking in the subs.
--
-- Or, tweak the speed to make it work out.
c_kampita :: Trill.Mode -> Derive.Generator Derive.Pitch
c_kampita mode = Derive.generator1 "kam" Tags.india
    "This is a kind of trill, but its interval defaults to NNs\
    \ scale, and transitions between the notes are smooth.  It's intended for\
    \ the vocal microtonal trills common in Carnatic music."
    $ Sig.call ((,,,)
    <$> required "pitch" "Base pitch."
    <*> defaulted "neighbor"
        (Sig.typed_control "trill-neighbor" 1 Score.Untyped)
        "Alternate with a pitch at this interval. If untyped, it's NNs,\
        \ otherwise it can be chromatic or diatonic."
    <*> defaulted "speed" (Sig.typed_control "trill-speed" 6 Score.Real)
        "Alternate pitches at this speed."
    <*> defaulted "slope" 8
        "Pitch moves at a maximum of this many NNs per second."
    ) $ \(pitch, neighbor, speed, slope) args -> do
        srate <- Util.get_srate
        neighbor <- Util.to_signal neighbor
        control <- case Score.type_of neighbor of
            Score.Untyped -> return Controls.nn
            Score.Diatonic -> return Controls.diatonic
            Score.Chromatic -> return Controls.chromatic
            typ -> Derive.throw $
                "expected untyped, diatonic, or chromatic: " ++ show typ
        transpose <- SignalTransform.slew_limiter srate slope <$>
            trill_signal mode (Args.range_or_next args)
                (Score.typed_val neighbor) speed
        start <- Args.real_start args
        return $ PitchSignal.apply_control control
            (Score.untyped transpose) $ PitchSignal.signal [(start, pitch)]

trill_signal :: Trill.Mode -> (ScoreTime, ScoreTime) -> Signal.Control
    -> TrackLang.ValControl -> Derive.Deriver Signal.Control
trill_signal mode range neighbor speed = do
    transitions <- Trill.trill_transitions range speed
    return $ trill_from_transitions mode transitions neighbor

-- | Make a trill signal from a list of transition times.
trill_from_transitions :: Trill.Mode -> [RealTime] -> Signal.Control
    -> Signal.Control
trill_from_transitions mode transitions neighbor =
    Signal.signal [(x, if t then Signal.at x neighbor else 0)
        | (x, t) <- zip transitions (cycle ts)]
    where
    ts = case mode of
        Trill.UnisonFirst -> [False, True]
        Trill.NeighborFirst -> [True, False]

c_jaru :: Derive.Generator Derive.Pitch
c_jaru = Derive.generator1 "jaru" Tags.india
    "This is a series of grace notes whose pitches are relative to the given\
    \ base pitch."
    $ Sig.call ((,,,)
    <$> required "pitch" "Base pitch."
    <*> Sig.many1 "interval" "Intervals from base pitch."
    <*> Sig.environ "time" jaru_time_default "Time for each note."
    <*> Sig.environ "transition" Nothing
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
    -- Do you think this is too much work?  I think it's too much work.
    parse intervals
        | all (==typ) types = return (xs, Util.transpose_control typ)
        | otherwise =
            Derive.throw "all intervals must be either diatonic or chromatic"
        where
        (xs, typ :| types) = NonEmpty.unzip $
            NonEmpty.map (Util.split_transpose . TrackLang.default_diatonic)
                intervals

c_jaru_intervals :: Util.TransposeType -> [Signal.Y]
    -> Derive.Generator Derive.Pitch
c_jaru_intervals transpose intervals = Derive.generator1 "jaru" Tags.india
    ("This is `jaru` hardcoded to " <> Pretty.prettytxt intervals <> ".")
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

jaru_time_default :: RealTime
jaru_time_default = 0.15

jaru :: RealTime -> RealTime -> RealTime -> RealTime -> [Signal.Y]
    -> Signal.Control
jaru srate start time transition intervals =
    SignalTransform.smooth id srate (-transition) $
        Signal.signal (zip (Seq.range_ start time) (intervals ++ [0]))
