-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE TypeSynonymInstances #-}
-- | Extract things from the PassedArgs data structure.
module Derive.Args where
import Util.Control
import qualified Util.Seq as Seq
import qualified Ui.Event as Event
import qualified Derive.Derive as Derive
import Derive.Derive (PassedArgs, CallInfo)
import qualified Derive.Eval as Eval
import qualified Derive.Parse as Parse
import qualified Derive.PitchSignal as PitchSignal
import qualified Derive.Score as Score

import qualified Perform.Signal as Signal
import Types


info :: PassedArgs a -> CallInfo a
info = Derive.passed_info

event :: PassedArgs a -> Event.Event
event = Derive.info_event . info

prev_control :: Derive.ControlArgs -> Maybe (RealTime, Signal.Y)
prev_control = Signal.last <=< prev_val

prev_pitch :: Derive.PitchArgs -> Maybe (RealTime, PitchSignal.Pitch)
prev_pitch = PitchSignal.last <=< prev_val

prev_score_event :: Derive.NoteArgs -> Maybe Score.Event
prev_score_event = prev_val

-- | Get the previous val.  See NOTE [prev-val].
prev_val :: PassedArgs a -> Maybe a
prev_val = Derive.info_prev_val . info

-- | Unused, but might be used again if I need to evaluate the next event.
eval :: Derive.Callable d => CallInfo x -> Event.Event
    -> [Event.Event] -> Derive.LogsDeriver d
eval cinfo event prev = case Parse.parse_expr text of
    Left err -> Derive.throw $ "parse error: " ++ err
    Right expr -> Eval.eval_expr False prev_cinfo expr
        where
        prev_cinfo = cinfo
            { Derive.info_expr = text
            , Derive.info_prev_val = Nothing
            , Derive.info_event = event
            , Derive.info_prev_events = prev
            , Derive.info_next_events =
                Derive.info_event cinfo : Derive.info_next_events cinfo
            , Derive.info_event_end = Event.start $ Derive.info_event cinfo
            }
    where text = Event.event_text event

-- * event timing

start :: PassedArgs a -> ScoreTime
start = Event.start . event

duration :: PassedArgs a -> ScoreTime
duration = Event.duration . event

real_start :: PassedArgs a -> Derive.Deriver RealTime
real_start = Derive.real . start

end :: PassedArgs a -> ScoreTime
end = Event.end . event

real_end :: PassedArgs a -> Derive.Deriver RealTime
real_end = Derive.real . end

-- | The start of the next event, or the end of the block if there is no next
-- event.
--
-- Used by calls to determine their extent, especially control calls, which
-- have no explicit duration.
next :: PassedArgs a -> ScoreTime
next = Derive.info_event_end . info

-- | End of the next event, or the end of the block if there is no next event.
next_end :: PassedArgs a -> ScoreTime
next_end args = maybe (next args) Event.end (Seq.head (next_events args))

-- | Get the start of the next event, if there is one.
--
-- This is similar to 'next', except that it will be Nothing at the end of
-- the block.
next_start :: PassedArgs a -> Maybe ScoreTime
next_start = fmap Event.start . Seq.head . next_events

prev_start :: PassedArgs a -> Maybe ScoreTime
prev_start = fmap Event.start . Seq.head . prev_events

prev_end :: PassedArgs a -> Maybe ScoreTime
prev_end = fmap Event.end . Seq.head . prev_events

prev_events, next_events :: PassedArgs a -> [Event.Event]
next_events = Derive.info_next_events . info
prev_events = Derive.info_prev_events . info

-- ** range

-- | Range of the called event, i.e. (start, end).  Note that range is the
-- minimum to maximum, which is not the same as the start and end if the event
-- has negative duration.
range :: PassedArgs a -> (ScoreTime, ScoreTime)
range = Event.range . event

real_range :: PassedArgs a -> Derive.Deriver (RealTime, RealTime)
real_range args = (,) <$> Derive.real start <*> Derive.real end
    where (start, end) = range args

-- | Like 'range', but if the duration is 0, then the end is 'next' event.
range_or_next :: PassedArgs a -> (ScoreTime, ScoreTime)
range_or_next args
    | start == end = (start, next args)
    | otherwise = (start, end)
    where (start, end) = range args

real_range_or_next :: PassedArgs a -> Derive.Deriver (RealTime, RealTime)
real_range_or_next args = (,) <$> Derive.real start <*> Derive.real end
    where (start, end) = range_or_next args

-- | Start and duration of the event.  This is probably the right thing for
-- calls that generate a note since it will give a negative duration when
-- appropriate.
extent :: PassedArgs a -> (ScoreTime, ScoreTime)
extent = (\e -> (Event.start e, Event.duration e)) . event

real_extent :: PassedArgs a -> Derive.Deriver (RealTime, RealTime)
real_extent args = do
    let e = event args
    start <- Derive.real (Event.start e)
    end <- Derive.real (Event.end e)
    return (start, end - start)

-- | Event range as it appears on the track, regardless of slicing.
range_on_track :: PassedArgs a -> (TrackTime, TrackTime)
range_on_track args = (shifted + start, shifted + end)
    where
    (start, end) = range args
    shifted = Derive.info_track_shifted (info args)

-- | This normalizes a deriver to start at 0 and have a duration of 1, provided
-- that the deriver is placed at the start and dur of the given args.  This is
-- the case if the deriver is a transformer arg, so this is useful for
-- a transformer to manipulate its argument.
normalized :: PassedArgs a -> Derive.Deriver b -> Derive.Deriver b
normalized args = Derive.place (- (start / dur)) (1 / dur)
    where
    (start, dur_) = extent args
    dur = if dur_ == 0 then 1 else dur_

{- NOTE [prev-val]

    Many control calls rely on the last value emitted by the previous call.
    I can't think of a way around that, because it's really fundamental to how
    the notation works, and it would be a real pain (and redundant) to have to
    write where interpolation comes from all the time.

    So conceptually each call takes the last val of the previous one as an
    argument.  This is problematic because it means you never know how far back
    in the track a given call's dependence extends.  Since track slicing
    divides control tracks into lots of little chunks it's not so simple to
    get the previous value.

    Initially I relied entirely on 'Derive.info_prev_val' and a hack where
    certain calls were marked as requiring the previous value, which 'slice'
    would then use.  The problem with that is that slice is working purely
    syntactically, and it doesn't know what's really in scope, nor does it
    understand val calls.  This is #2 below.

    After that, I tried #3, but ran into trouble wanting to get the previous
    Score.Event.  Actually, I could have supported Score.Event with the
    evaluating technique, but I forgot that I had already done all these work
    before, implemented most of #2 before stumbling on #1 again, when its
    earlier problems seemed less severe than before.

    So the current solution is #1.

    1. Extend the 'Derive.info_prev_val' mechanism to work even across sliced
    tracks.  Since they are no longer evaluated in sequence, I have to save
    them in a `Map (BlockId, TrackId) (RealTime, Either Signal.Y
    PitchSignal.Pitch))`.  However, this is problematic in its own way because
    it's actually threaded state, which is new.  This isn't actually so bad,
    because I would add it in a new Threaded state, and it's only making
    explicit the already threaded nature of track derivation, due to prev_val.
    An additional problem is that, once again due to slicing, control events
    are evaluated twice, which means that the second evaluation gets the first
    evaluation's value as it's \"previous\" value.  An extra hack in
    "Derive.EvalTrack" avoids recording a previous value when the event is past
    the end of a slice.

    2. Make 'slice' figure out which calls will need the previous val.  This is
    like the old syntactic mechanism only more robust.  Calls already include
    a `prev` tag that indicates they rely on the previous value.  This is
    complicated because what is in scope can change dynamically, so the slicing
    has to be done under the track's transform at least.  That means slicing
    is split into two halves, where the first part just marks slice boundaries,
    and the actual slice is done in the track deriver.

    3. If a call doesn't have a prev val already, it can go evaluate the prev
    event itself, which must be able to continue recursively until there really
    isn't a prev event.  This can do more work, but is appealing because it
    removes the serialization requirement of 'Derive.info_prev_val'.
        - This means if multiple calls want the prev val, it'll be evaluated
        multiple times, unless I cache it somehow.
        - I should clear out the next events so it doesn't get in a loop if it
        wants the next event.  Actually it's fine if it wants to look at it, it
        just can't want to evaluate it.
-}
