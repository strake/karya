module Derive.Call.Rambat where
import Data.FixedList (Cons(..), Nil(..))

import Util.Control
import qualified Derive.Call.Util as Util
import qualified Derive.CallSig as CallSig
import Derive.CallSig (optional, control)
import qualified Derive.Derive as Derive
import qualified Derive.Pitches as Pitches

import qualified Perform.Pitch as Pitch
import qualified Perform.RealTime as RealTime
import qualified Perform.Signal as Signal

import Types


note_calls :: Derive.NoteCallMap
note_calls = Derive.make_calls
    [ ("tick", c_tick)
    ]

-- | Insert an intermediate grace note in the rambat style.  The grace note
-- precedes the following note, and is one step above or one step below
-- depending on the preceding note.
--
-- This is not an inverting call since it needs know the pitches of the
-- previous and following notes.
--
-- TODO damping
--
-- [time /Control/ @%tick-time,.2@] Time from the grace note to the following
-- note.  This is in absolute time, but will be halfway between the previous
-- and next note if there isn't this much time.
--
-- [vel /Control/ @%tick-velocity,.3@] Grace note velocity will be this
-- percentage of the following note.
c_tick :: Derive.NoteCall
c_tick = Derive.stream_generator "tick" $ \args -> CallSig.call2 args
    ( optional "time" (control "tick-time" 0.15)
    , optional "vel" (control "tick-velocity" 0.5)) $ \time vel ->
    case (Derive.passed_prev_begin args, Derive.passed_next_begin args) of
        (Just ppos, Just npos) ->
            Util.with_controls args (time :. vel :. Nil) $
                \(time :. vel :. Nil) ->
                    tick (Signal.y_to_real time) vel ppos npos
        (Nothing, Just _) -> Derive.throw "no previous event"
        _ -> Derive.throw "no next event"

tick :: RealTime -> Signal.Y -> ScoreTime -> ScoreTime -> Derive.EventDeriver
tick time vel prev next = do
    prev_pitch <- Derive.require "previous pitch"
        =<< Derive.pitch_at =<< Derive.real prev
    next_pitch <- Derive.require "next pitch"
        =<< Derive.pitch_at =<< Derive.real next
    next_vel <- Util.velocity =<< Derive.real next
    neighbor <- ifM
        ((<=) <$> Pitches.pitch_nn prev_pitch <*> Pitches.pitch_nn next_pitch)
        (return (Pitch.Chromatic (-1))) (return (Pitch.Chromatic 1))
    (start, dur) <- stretch prev next time
    Derive.d_place start dur $ Util.simple_note
        (Pitches.transpose neighbor next_pitch) (next_vel * vel)

-- TODO if I need to do more note shifting and placing, I could dream up some
-- sort of constraint language like TeX's notion of stretchiness
stretch :: ScoreTime -> ScoreTime -> RealTime
    -> Derive.Deriver (ScoreTime, ScoreTime)
stretch prev next offset = do
    real_prev <- Derive.real prev
    real_next <- Derive.real next
    -- Try to use the offset, but use the midpoint if there isn't room.
    let real_pos = max (real_next - offset)
            ((real_prev + real_next) `RealTime.div` 2)
    pos <- Derive.score real_pos
    return (pos, next - pos)
