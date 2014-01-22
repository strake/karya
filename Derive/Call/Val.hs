-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.Call.Val where
import qualified Data.Monoid as Monoid

import Util.Control
import qualified Util.Num as Num
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq

import qualified Ui.Event as Event
import qualified Ui.ScoreTime as ScoreTime
import qualified Derive.Args as Args
import qualified Derive.Call as Call
import qualified Derive.Call.Control as Control
import qualified Derive.Call.Make as Make
import qualified Derive.Call.Pitch as Call.Pitch
import qualified Derive.Call.Tags as Tags
import qualified Derive.Call.Util as Util
import qualified Derive.Derive as Derive
import qualified Derive.LEvent as LEvent
import qualified Derive.PitchSignal as PitchSignal
import qualified Derive.Pitches as Pitches
import qualified Derive.Scale as Scale
import qualified Derive.Score as Score
import qualified Derive.Sig as Sig
import Derive.Sig (defaulted, required)
import qualified Derive.TrackInfo as TrackInfo
import qualified Derive.TrackLang as TrackLang

import qualified Perform.Pitch as Pitch
import qualified Perform.RealTime as RealTime
import qualified Perform.Signal as Signal

import Types


val_calls :: Derive.ValCallMap
val_calls = Derive.make_calls
    [ (">", c_next_val)
    , ("<", c_prev_val)
    , ("e", c_env)
    , ("ts", c_timestep)
    , ("ts/", c_timestep_reciprocal)
    , ("1/", c_reciprocal)
    , ("nn", c_nn)
    , ("hz", c_hz)
    , ("st", c_scoretime)
    , ("rt", c_realtime)
    , ("pitch", c_pitch)

    -- lookup
    , ("#", c_pitch_signal)

    -- generate signals
    , ("i>", c_linear_next)
    , ("e>", c_exp_next)
    ]

c_next_val :: Derive.ValCall
c_next_val = Derive.val_call "next-val" Tags.next
    "Evaluate the next event. Only works on pitch and control tracks, and\
    \ if the next event doesn't need its previous event."
    $ Sig.call0 $ \args -> do
        event <- Derive.require "no next event" $
            Seq.head (Args.next_events args)
        start <- Derive.real (Event.start event)
        next_val event start (Derive.info_track_type (Derive.passed_info args))

next_val :: Event.Event -> RealTime -> Maybe TrackInfo.Type
    -> Derive.Deriver TrackLang.Val
next_val event start ttype = case ttype of
    Just TrackInfo.ControlTrack -> eval_control start event
    Just TrackInfo.TempoTrack -> eval_control start event
    Just TrackInfo.PitchTrack -> do
        signal <- eval event
        case PitchSignal.at start signal of
            Nothing -> Derive.throw "next pitch event didn't emit a pitch"
            Just pitch -> return $ TrackLang.VPitch pitch
    Just TrackInfo.NoteTrack ->
        Derive.throw "can't get next value for note tracks"
    Nothing -> Derive.throw "no track type"
    where
    eval_control start event = do
        signal <- eval event
        return $ TrackLang.VNum $ Score.untyped $
            Signal.at start (signal :: Signal.Control)
    eval event = mconcat . LEvent.events_of <$>
        (either Derive.throw return =<< Call.eval_event event)

c_prev_val :: Derive.ValCall
c_prev_val = Derive.val_call "prev-val" Tags.prev
    "Return the previous value. Only works on pitch and control tracks."
    $ Sig.call0 $ \args -> Args.prev_val args >>= \x -> case x of
        Just (_, Derive.TagControl y) ->
            return (TrackLang.num y :: TrackLang.Val)
        Just (_, Derive.TagPitch y) -> return $ TrackLang.VPitch y
        _ -> Derive.throw "no previous value"

c_env :: Derive.ValCall
c_env = Derive.val_call "env" mempty
    "Look up the given val in the environ."
    $ Sig.call ((,)
    <$> required "name" "Look up the value of this key."
    <*> defaulted "default" Nothing "If given, this is the default value when\
        \ the key isn't present. If not given, a missing key will throw an\
        \ exception. The presence of a default will also make the lookup\
        \ expect the same type as the default."
    ) $ \(name, maybe_deflt) _args -> case maybe_deflt of
        Nothing -> Derive.get_val name
        Just deflt -> check name deflt =<< Derive.lookup_val name
    where
    check _ deflt Nothing = return deflt
    check name deflt (Just val)
        | TrackLang.type_of val == TrackLang.type_of deflt = return val
        | otherwise = Derive.throw $ "env " <> Pretty.pretty name
            <> " expected " <> Pretty.pretty (TrackLang.type_of deflt)
            <> " but got " <> Pretty.pretty (TrackLang.type_of val)

c_timestep :: Derive.ValCall
c_timestep = Derive.val_call "timestep" mempty
    ("Compute the duration of the given RelativeMark timestep at the current\
    \ position. This is for durations, so it only works with RelativeMark."
    ) $ Sig.call ((,)
    <$> required "rank" "Emit a duration of this rank."
    <*> defaulted "multiply" 1 "Multiply duration."
    ) $ \(TrackLang.E rank, steps) args ->
        TrackLang.score_time <$>
            Util.meter_duration (Args.start args) rank steps

c_timestep_reciprocal :: Derive.ValCall
c_timestep_reciprocal = Make.modify_vcall c_timestep "timestep-reciprocal"
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
            else return (1 / num :: Double)

c_nn :: Derive.ValCall
c_nn = Derive.val_call "nn" mempty
    "Convert a pitch or hz to a NoteNumber." $ Sig.call (required "val" "") $
    \val _ -> case val of
        Left pitch -> realToFrac <$> Pitches.pitch_nn pitch
        Right hz -> return (realToFrac (Pitch.hz_to_nn hz) :: Double)

c_hz :: Derive.ValCall
c_hz = Derive.val_call "hz" mempty
    "Convert a pitch or NoteNumber to hz." $ Sig.call (required "val" "") $
    \val _ -> case val of
        Left pitch -> Pitch.nn_to_hz <$> Pitches.pitch_nn pitch
        Right nn -> return (Pitch.nn_to_hz (Pitch.NoteNumber nn) :: Double)

c_scoretime :: Derive.ValCall
c_scoretime = Derive.val_call "scoretime" mempty
    "Convert a number to ScoreTime. This just changes the type annotation, the\
    \ value remains the same." $
    Sig.call (Sig.required_env "val" Sig.None "") $ \val _ ->
        return $ ScoreTime.double val

c_realtime :: Derive.ValCall
c_realtime = Derive.val_call "realtime" mempty
    "Convert a number to RealTime. This just changes the type annotation, the\
    \ value remains the same." $
    Sig.call (Sig.required_env "val" Sig.None "") $ \val _ ->
        return $ RealTime.seconds val

c_pitch :: Derive.ValCall
c_pitch = Derive.val_call "pitch" mempty "Create a 'Perform.Pitch.Pitch'."
    $ Sig.call ((,,)
    <$> Sig.defaulted_env "oct" Sig.None (Left 0)
        "Octave, or a pitch name or pitch. If it's a pitch name or pitch, the\
        \ `pc` and `accs` args must be 0."
    <*> Sig.defaulted_env "pc" Sig.None 0 "Pitch class."
    <*> Sig.defaulted_env "accs" Sig.None 0 "Accidentals."
    ) $ \(oct, pc, accs) _ -> make_pitch oct pc accs

make_pitch :: Either Pitch.Octave (Either Text PitchSignal.Pitch)
    -> Pitch.PitchClass -> Pitch.Accidentals -> Derive.Deriver Pitch.Pitch
make_pitch (Left oct) pc accs = return $ Pitch.Pitch oct (Pitch.Degree pc accs)
make_pitch (Right name_pitch) pc accs
    | pc /= 0 || accs /= 0 = Derive.throw $
        "pc and accs args must be 0 when a pitch is given: " ++ show (pc, accs)
    | otherwise = do
        (note, scale) <- case name_pitch of
            Left name -> (,) <$> return (Pitch.Note name) <*> Util.get_scale
            Right pitch -> (,) <$> Pitches.pitch_note pitch
                <*> Derive.get_scale (PitchSignal.pitch_scale_id pitch)
        key <- Util.lookup_key
        either (Derive.throw . Pretty.pretty) return $
            Scale.scale_read scale key note

-- * lookup

c_pitch_signal :: Derive.ValCall
c_pitch_signal = Derive.val_call "pitch" mempty
    "Get the current pitch." $ Sig.call (defaulted "control" ""
        "The default pitch if empty, otherwise, get the named pitch.") $
    \control args ->
        Derive.require "pitch" =<< get control =<< Args.real_start args
    where
    get control
        | control == "" = Derive.pitch_at
        | otherwise = Derive.named_pitch_at (Score.control control)

-- * generate signals

c_linear_next :: Derive.ValCall
c_linear_next = Derive.val_call "linear-next" mempty
    "Create straight lines between the given breakpoints."
    $ Sig.call breakpoints_arg $ \vals args ->
        c_breakpoints 0 id vals args

c_exp_next :: Derive.ValCall
c_exp_next = Derive.val_call "exp-next" mempty
    "Create curved lines between the given breakpoints."
    $ Sig.call ((,)
    <$> defaulted "exp" 2 Control.exp_doc
    <*> breakpoints_arg
    ) $ \(exp, vals) args ->
        c_breakpoints 1 (Control.expon exp) vals args

breakpoints_arg :: Sig.Parser (NonEmpty TrackLang.Val)
breakpoints_arg = Sig.many1 "bp" "Breakpoints are distributed evenly between\
    \ the event start and the next event. They can be all numbers, or all\
    \ pitches."

-- ** implementation

c_breakpoints :: Int -> (Double -> Double) -> NonEmpty TrackLang.Val
    -> Derive.PassedArgs a -> Derive.Deriver TrackLang.Val
c_breakpoints argnum f vals args = do
    (start, end) <- Args.real_range_or_next args
    srate <- Util.get_srate
    vals <- num_or_pitch argnum vals
    let pitch_breakpoints = make_segments PitchSignal.signal
            (Call.Pitch.interpolate_segment False srate f)
        control_breakpoints = make_segments Signal.signal
            (Control.interpolate_segment False srate f)
    return $ case vals of
        Left nums -> TrackLang.VControl $ TrackLang.ControlSignal $
            Score.untyped $ control_breakpoints start end nums
        Right pitches -> TrackLang.VPitchControl $ TrackLang.ControlSignal $
            pitch_breakpoints start end pitches

-- | Insist that the vals be either all numbers or pitches.
--
-- TODO If 'Sig.Parser' supported Alternative, maybe I could build this as
-- a parser and get both shorter code and documentation.
num_or_pitch :: Int -> NonEmpty TrackLang.Val
    -> Derive.Deriver (Either [Signal.Y] [PitchSignal.Pitch])
num_or_pitch argnum (val :| vals) = case val of
    TrackLang.VNum num -> do
        vals <- mapM (expect tnum) (zip [argnum + 1 ..] vals)
        return $ Left (Score.typed_val num : vals)
    TrackLang.VPitch pitch -> do
        vals <- mapM (expect TrackLang.TPitch) (zip [argnum + 1 ..] vals)
        return $ Right (pitch : vals)
    _ -> type_error argnum "bp" (TrackLang.TEither tnum TrackLang.TPitch) val
    where
    tnum = TrackLang.TNum TrackLang.TUntyped TrackLang.TAny
    expect typ (argnum, val) = maybe (type_error argnum "bp" typ val) return $
        TrackLang.from_val val

type_error :: Int -> Text -> TrackLang.Type -> TrackLang.Val -> Derive.Deriver a
type_error argnum name expected received =
    Derive.throw_error $ Derive.CallError $
        Derive.TypeError (Derive.TypeErrorArg argnum) Derive.Literal name
            expected (Just received)

make_segments :: (Monoid.Monoid sig) =>
    ([(RealTime, y)] -> sig)
    -> (RealTime -> y -> RealTime -> y -> sig)
    -> RealTime -> RealTime -> [y] -> sig
make_segments make_signal segment start end =
    mconcat . map line . Seq.zip_next . make_breakpoints start end
    where
    line ((x1, y1), Just (x2, y2)) = segment x1 y1 x2 y2
    line ((x1, y2), Nothing) = make_signal [(x1, y2)]

make_breakpoints :: RealTime -> RealTime -> [a] -> [(RealTime, a)]
make_breakpoints start end vals = case vals of
    [] -> []
    [x] -> [(start, x)]
    _ -> [(Num.scale start end (n / (len - 1)), x)
        | (n, x) <- zip (Seq.range_ 0 1) vals]
    where len = fromIntegral (length vals)
