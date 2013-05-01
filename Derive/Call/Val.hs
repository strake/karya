module Derive.Call.Val where
import Util.Control
import qualified Util.Seq as Seq
import qualified Ui.Event as Event
import qualified Derive.Args as Args
import qualified Derive.Call as Call
import qualified Derive.Call.Tags as Tags
import qualified Derive.Call.Util as Util
import qualified Derive.Derive as Derive
import qualified Derive.LEvent as LEvent
import qualified Derive.PitchSignal as PitchSignal
import qualified Derive.Score as Score
import qualified Derive.Sig as Sig
import Derive.Sig (defaulted, required)
import qualified Derive.TrackInfo as TrackInfo
import qualified Derive.TrackLang as TrackLang

import qualified Perform.Signal as Signal


val_calls :: Derive.ValCallMap
val_calls = Derive.make_calls
    [ (">", c_next_val)
    , ("<", c_prev_val)
    , ("t", c_timestep)
    , ("ts", c_timestep_reciprocal)
    , ("1/", c_reciprocal)
    ]

c_next_val :: Derive.ValCall
c_next_val = Derive.val_call "next-val" Tags.next
    "Evaluate the value of the next event. Only works on pitch and control\
    \ tracks." $ Sig.call0 $ \args -> do
        event <- Derive.require "no next event" $
            Seq.head (Args.next_events args)
        start <- Derive.real (Event.start event)
        case Derive.info_track_type (Derive.passed_info args) of
            Just TrackInfo.ControlTrack -> eval_control start event
            Just TrackInfo.TempoTrack -> eval_control start event
            Just TrackInfo.PitchTrack -> do
                signal <- eval event
                case PitchSignal.at start signal of
                    Nothing -> Derive.throw
                        "next pitch event didn't actually emit a pitch"
                    Just pitch -> return $ TrackLang.VPitch pitch
            Just TrackInfo.NoteTrack -> Derive.throw
                "can't get next value for note tracks"
            Nothing -> Derive.throw "no track type"
    where
    eval_control start event = do
        signal <- eval event
        return $ TrackLang.VNum $ Score.untyped $
            Signal.at start (signal :: Signal.Control)
    eval event = mconcat . LEvent.events_of <$>
        (either Derive.throw return =<< Call.eval_event event)

-- | This is less efficient than the various control and pitch calls that use
-- the prev val, because it has to re-evaluate the previous event and pick out
-- the last sample.  It has trouble re-using the already-computed previous
-- value because that would make 'Derive.ValCall' polymorphic which in turn
-- means it's hard to put into a single ValScope.
--
-- TODO maybe something could done with existentials, since the return value is
-- still monomorphic.
--
-- TODO This doesn't work for notes in other slices because (<) isn't in the
-- 'Pitch.require_previous' hack, which is because it wouldn't work if (<) is
-- in an expression.  I could make it work by including the prev events even in
-- sliced tracks, if I'm not evaluating them except when needed that should be
-- ok.
c_prev_val :: Derive.ValCall
c_prev_val = Derive.val_call "prev-val" Tags.prev
    ("Return the previous value. Only works on pitch and control tracks.\
    \ Unfortunately, this doesn't work when the next value is on a different\
    \ note, because of slicing."
    ) $ Sig.call0 $ \args -> do
        event <- Derive.require "no prev event" $
            Seq.head (Args.prev_events args)
        case Derive.info_track_type (Derive.passed_info args) of
            Just TrackInfo.ControlTrack -> eval_control event
            Just TrackInfo.TempoTrack -> eval_control event
            Just TrackInfo.PitchTrack -> do
                signal <- eval event
                case PitchSignal.last signal of
                    Nothing -> Derive.throw
                        "last pitch event didn't actually emit a pitch"
                    Just (_, pitch) -> return $ TrackLang.VPitch pitch
            Just TrackInfo.NoteTrack -> Derive.throw
                "can't get prev value for note tracks"
            Nothing -> Derive.throw "no track type"
    where
    eval_control event = do
        signal <- eval event
        return $ TrackLang.VNum $ Score.untyped $
            maybe 0 snd $ Signal.last (signal :: Signal.Control)
    eval event = mconcat . LEvent.events_of <$>
        (either Derive.throw return =<< Call.eval_event event)

eval_pitch :: Event.Event -> Derive.Deriver (Maybe PitchSignal.Pitch)
eval_pitch event =
    justm (either (const Nothing) Just <$> Call.eval_event event) $ \strm -> do
    start <- Derive.real (Event.start event)
    return $ PitchSignal.at start $ mconcat $ LEvent.events_of strm

c_timestep :: Derive.ValCall
c_timestep = Derive.val_call "timestep" mempty
    ("Compute the duration of the given RelativeMark timestep at the current\
    \ position. This is for durations, so it only works with RelativeMark, and\
    \ in fact prepends `r:`, so e.g. a quarter note is just `q`."
    ) $ Sig.call ((,)
    <$> required "rank" "Emit a duration of this rank, as accepted by\
        \ `TimeStep.parse_rank`."
    <*> defaulted "steps" 1 "Step this number of times, negative to step back."
    ) $ \(rank, steps) args ->
        TrackLang.score_time <$>
            Util.parsed_meter_duration (Args.start args) rank steps

c_timestep_reciprocal :: Derive.ValCall
c_timestep_reciprocal = Sig.modify_vcall c_timestep "timestep-reciprocal"
    ("This is the same as `timestep` except it returns the reciprocal. This is\
    \ useful for e.g. trills which take cycles per second rather than duration."
    ) reciprocal
    where
    reciprocal (TrackLang.VNum num) = TrackLang.VNum $ recip <$> num
    reciprocal val = val

c_reciprocal :: Derive.ValCall
c_reciprocal = Derive.val_call "reciprocal" mempty
    "Find the reciprocal of a number. Useful for tempo, e.g. set the tempo to\
    \ 1/time." $ Sig.call (required "num" "") $ \num _ ->
        if num == 0 then Derive.throw "1/0"
            else return $ TrackLang.num (1 / num)
