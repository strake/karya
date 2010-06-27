{-# LANGUAGE GeneralizedNewtypeDeriving, PatternGuards, ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeSynonymInstances #-}
{- | Main module for the deriver monad.

    Derivers are always in DeriveT, even if they don't need its facilities.
    This makes them more regular to compose.  The convention is to prepend
    deriver names with 'd_', so if the deriver is normally implemented purely,
    a d_ version can be made simply by composing 'return'.

    I have a similar sort of setup to nyquist, with a \"transformation
    environment\" that functions can look at to implement behavioral
    abstraction.  The main differences are that I don't actually generate audio
    signal, but my \"ugens\" eventually render down to MIDI or OSC (or even
    nyquist or csound source!).

    \"Stack\" handling here is kind of confusing.

    The end goal is that log messages and exceptions are tagged with the place
    they occurred.  This is called the stack, and is described in
    'Perform.Warning.Stack'.  Since the stack elements indicate positions on
    the screen, they should be in unwarped score time, not real time.

    The current stack is stored in 'state_stack' and will be added to by
    'with_stack_block', 'with_stack_track', and 'with_stack_pos' as the deriver
    processes a block, a track, and individual events respectively.
    'warn' and 'throw' will pick the current stack out of 'state_stack'.

    When 'Derive.Score.Event's are emitted they are also given the stack at the
    time of their derivation.  If there is a problem in performance, log msgs
    still have access to the stack.
-}
module Derive.Derive where
import Control.Monad
import qualified Control.Monad.Error as Error
import qualified Control.Monad.Identity as Identity
import qualified Control.Monad.State.Strict as Monad.State
import qualified Control.Monad.Trans as Trans
import Control.Monad.Trans (lift)
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Monoid as Monoid

import Util.Control
import qualified Util.Log as Log
import qualified Util.Seq as Seq
import qualified Util.SrcPos as SrcPos

import Ui
import qualified Ui.Block as Block
import qualified Ui.Event as Event
import qualified Ui.State as State
import qualified Ui.Track as Track
import qualified Ui.Types as Types

import qualified Perform.PitchSignal as PitchSignal
import qualified Perform.Signal as Signal
import qualified Perform.Pitch as Pitch
import qualified Perform.Timestamp as Timestamp
import qualified Perform.Transport as Transport
import qualified Perform.Warning as Warning

import qualified Derive.Scale as Scale
import qualified Derive.Score as Score
import qualified Derive.TrackLang as TrackLang


-- * DeriveT

type Deriver a = DeriveT Identity.Identity a

-- ** events

type EventDeriver = Deriver Events
type Events = [Score.Event]

no_events :: Events
no_events = []

empty_events :: EventDeriver
empty_events = return no_events

-- ** control

type ControlDeriver = Deriver Control
type Control = Signal.Control
type DisplaySignalDeriver = Deriver [(TrackId, Signal.Display)]

no_control :: Control
no_control = Signal.empty

empty_control :: ControlDeriver
empty_control = return no_control

-- ** pitch

type PitchDeriver = Deriver PitchSignal.PitchSignal
type Pitch = PitchSignal.PitchSignal

no_pitch :: Pitch
no_pitch = PitchSignal.empty

empty_pitch :: PitchDeriver
empty_pitch = return no_pitch

-- ** state

-- TODO remove this
type TrackDeriver m e = TrackId -> DeriveT m [e]

newtype DeriveT m a = DeriveT (DeriveStack m a)
    deriving (Functor, Monad, Trans.MonadIO, Error.MonadError DeriveError)
run_derive_t (DeriveT m) = m

type DeriveStack m = Error.ErrorT DeriveError
    (Monad.State.StateT State
        (Log.LogT m))

data State = State {
    -- Environment.  These form a dynamically scoped environment that applies
    -- to generated events inside its scope.

    -- | Derivers can modify it for sub-derivers, or look at it, whether to
    -- attach to an Event or to handle internally.
    state_controls :: Score.WarpedControls
    -- | Absolute pitch signal currently in scope.
    , state_pitch :: PitchSignal.PitchSignal
    -- TODO unify this with Score.WarpedControls
    -- I can do this when I support multiple pitch signals
    , state_pitch_warp :: Score.Warp

    , state_environ :: TrackLang.Environ
    , state_warp :: Score.Warp
    -- | This is the call stack for events.  It's used for error reporting,
    -- and attached to events in case they want to emit errors later (say
    -- during performance).  This is not a Warning.Stack becasue it's kept in
    -- reverse order for ease of construction.
    , state_stack :: [Warning.StackPos]
    -- | This is a free-form stack which can be used to record call sequences
    -- in derivation.  It represents logical position during derivation rather
    -- than position on the score.
    , state_log_context :: [String]

    -- | Remember the warp signal for each track.  A warp usually a applies to
    -- a set of tracks, so remembering them together will make the updater more
    -- efficient when it inverts them to get playback position.
    , state_track_warps :: [TrackWarp]

    -- | Constant throughout the derivation.  Used to look up tracks and
    -- blocks.
    , state_ui :: State.State
    , state_lookup_deriver :: LookupDeriver
    , state_control_op_map :: Map.Map TrackLang.CallId ControlOp
    , state_pitch_op_map :: Map.Map TrackLang.CallId PitchOp
    , state_call_map :: CallMap
    -- | This is set if the derivation is for a signal deriver.  Signal
    -- derivers skip all special tempo treatment.  Ultimately, this is needed
    -- because of the 'add_track_warp' hack.  It might be 'add_track_warp' is
    -- too error-prone to allow to live...
    , state_ignore_tempo :: Bool
    }

initial_state ui_state lookup_deriver calls ignore_tempo = State {
    state_controls = initial_controls
    , state_pitch = PitchSignal.constant
        (State.state_project_scale ui_state) Pitch.middle_degree
    , state_pitch_warp = Score.id_warp

    , state_environ = initial_environ
    , state_warp = Score.id_warp
    , state_stack = []
    , state_log_context = []

    , state_track_warps = []
    , state_ui = ui_state
    , state_lookup_deriver = lookup_deriver
    , state_control_op_map = default_control_op_map
    , state_pitch_op_map = default_pitch_op_map
    , state_call_map = calls
    , state_ignore_tempo = ignore_tempo
    }

-- | Initial control environment.
initial_controls :: Score.WarpedControls
initial_controls = Score.warped_controls
    [(Score.c_velocity, Signal.constant default_velocity)]

initial_environ :: TrackLang.Environ
initial_environ = Map.fromList
    [ (TrackLang.v_srate, TrackLang.VNum 0.05)
    ]

-- | See 'Perform.Midi.Perform.default_velocity' for 0.79.
default_velocity :: Signal.Y
default_velocity = 0.79

-- ** calls

data CallMap = CallMap {
    calls_note :: NoteCallMap
    , calls_control :: ControlCallMap
    , calls_pitch :: PitchCallMap
    }
empty_call_map = CallMap Map.empty Map.empty Map.empty

type NoteCallMap = Map.Map TrackLang.CallId NoteCall
type ControlCallMap = Map.Map TrackLang.CallId ControlCall
type PitchCallMap = Map.Map TrackLang.CallId PitchCall

-- | A Call will be called as either a generator or a transformer, depending on
-- its position.  A call at the end of a compose pipeline will be called as
-- a generator while ones composed with it will be called as transformers, so
-- in @a | b@, @a@ is a transformer and @b@ is a generator.
data Call y derived = Call {
    -- | Since call IDs may be rebound dynamically, each call has its own name
    -- so that error msgs are unambiguous.
    call_name :: String
    , call_generator :: Maybe (GeneratorCall y derived)
    , call_transformer :: Maybe (TransformerCall y derived)
    }

type NoteCall = Call Score.Event Events
type ControlCall = Call Signal.Y Control
type PitchCall = Call PitchSignal.Y Pitch

-- | args -> prev_events -> cur_event -> next_events -> (deriver, consumed)
type GeneratorCall y derived = TrackLang.PassedArgs y -> [Track.PosEvent]
    -> Event.Event -> [Track.PosEvent]
    -> Either TrackLang.TypeError (Deriver derived, Int)
-- | args -> (deriver -> deriver)
type TransformerCall y derived = TrackLang.PassedArgs y -> Deriver derived
    -> Either TrackLang.TypeError (Deriver derived)

-- | The call for the whole control track.
type ControlTrackCall = BlockId -> TrackId -> TrackLang.PassedArgs Signal.Y
    -> Deriver Transformer
type Transformer = EventDeriver -> EventDeriver

generator :: String -> GeneratorCall y derived -> Call y derived
generator name call = Call name (Just call) Nothing

transformer :: String -> TransformerCall y derived -> Call y derived
transformer name call = Call name Nothing (Just call)

-- | Like 'generator', except for a generator that consumes a single event.
generate_one :: String
    -> (TrackLang.PassedArgs y -> [Track.PosEvent] -> Event.Event
    -> [Track.PosEvent]
    -> Either TrackLang.TypeError (Deriver derived))
    -> Call y derived
generate_one name call = generator name $ \args prev event next ->
    fmap (, 1) (call args prev event next)

make_calls :: [(String, Call y derived)]
    -> Map.Map TrackLang.CallId (Call y derived)
make_calls = Map.fromList . map (first TrackLang.Symbol)

instance Show CallMap where
    show (CallMap note control pitch) =
        "(CallMap " ++ keys note ++ " " ++ keys control ++ " " ++ keys pitch
        ++ ")"
        where
        keys m = "<" ++ Seq.join ", " [c | TrackLang.Symbol c <- Map.keys m]
            ++ ">"

-- ** state support

-- | Since the deriver may vary based on the block, this is needed to find
-- the appropriate deriver.  It's created by 'Schema.lookup_deriver'.
type LookupDeriver = BlockId -> Either State.StateError EventDeriver

-- | LookupDeriver that suppresses all sub-derivations.  Used by the signal
-- deriver since it only derives one block at a time.
empty_lookup_deriver :: LookupDeriver
empty_lookup_deriver = const (Right empty_events)

-- | Each track warp is a warp indexed by the block and tracks it covers.
data TrackWarp = TrackWarp {
    tw_start :: RealTime
    , tw_end :: RealTime
    , tw_block :: BlockId
    , tw_tracks :: [TrackId]
    , tw_warp :: Score.Warp
    } deriving (Show)

data DeriveError = DeriveError SrcPos.SrcPos [Warning.StackPos] String
    deriving (Eq)
instance Error.Error DeriveError where
    strMsg = DeriveError Nothing []
instance Show DeriveError where
    show (DeriveError srcpos stack msg) =
        "<DeriveError " ++ SrcPos.show_srcpos srcpos ++ " "
        ++ Log.show_stack stack ++ ": " ++ msg ++ ">"

error_message (DeriveError _ _ s) = s

instance Monad m => Log.LogMonad (DeriveT m) where
    write = DeriveT . lift . lift . Log.write


-- * monadic ops

derive :: LookupDeriver -> State.State -> CallMap -> Bool
    -> DeriveT Identity.Identity a
    -> (Either DeriveError a,
        Transport.TempoFunction, Transport.InverseTempoFunction, [Log.Msg],
        State) -- ^ State is not actually needed, but is handy for testing.
derive lookup_deriver ui_state calls ignore_tempo deriver =
    (result, tempo_func, inv_tempo_func, logs, state)
    where
    (result, state, logs) = Identity.runIdentity $
        run (initial_state ui_state lookup_deriver calls ignore_tempo) deriver
    track_warps = state_track_warps state
    tempo_func = make_tempo_func track_warps
    inv_tempo_func = make_inverse_tempo_func track_warps

-- | Just like 'd_block', except run toplevel post processing.
d_root_block :: BlockId -> EventDeriver
d_root_block = fmap process_negative_durations . d_block

d_block :: BlockId -> EventDeriver
d_block block_id = do
    -- Do some error checking.  These are all caught later, but if I throw here
    -- the stack doesn't include the bogus block yet and I can give more
    -- specific error msgs.
    let bthrow s = throw ("d_block " ++ show block_id ++ ": " ++ s)
    ui_state <- gets state_ui
    case Map.lookup block_id (State.state_blocks ui_state) of
        Nothing -> bthrow "block_id not found"
        _ -> return ()
    stack <- gets state_stack
    -- Since there is no branching, any recursion will be endless.
    when (block_id `elem` [bid | (bid, _, _) <- stack]) $
        bthrow "recursive block derivation"
    block_dur <- get_block_dur block_id
    when (block_dur <= 0) $
        bthrow "block with zero duration"
    state <- get
    let rethrow exc = bthrow $ "lookup deriver for " ++ show block_id
            ++ ": " ++ show exc
    deriver <- either rethrow return (state_lookup_deriver state block_id)
    with_stack_block block_id deriver

-- | Run a derivation, catching and logging any exception.
d_subderive :: (Monad m) => a -> DeriveT Identity.Identity a -> DeriveT m a
d_subderive fail_val deriver = do
    state <- get
    let (res, state2, logs) = Identity.runIdentity $ run state deriver
    mapM_ Log.write logs
    case res of
        Left (DeriveError srcpos stack msg) -> do
            -- I don't use 'warn', which means I don't get the local context,
            -- but I think that's ok because the msg gets the sub-block's
            -- context.
            Log.write $
                (Log.msg_srcpos srcpos Log.Warn ("subderiving: " ++ msg))
                { Log.msg_stack = Just stack }
            return fail_val
        Right val -> do
            -- TODO once the logging portion of the state is factored out I
            -- should copy back only that part
            modify (const state2)
            return val


run :: (Monad m) =>
    State -> DeriveT m a -> m (Either DeriveError a, State, [Log.Msg])
run derive_state m = do
    ((err, state2), logs) <- (Log.run . flip Monad.State.runStateT derive_state
        . Error.runErrorT . run_derive_t) m
    return (err, state2, logs)

make_tempo_func :: [TrackWarp] -> Transport.TempoFunction
make_tempo_func track_warps block_id track_id pos = do
    warp <- lookup_track_warp block_id track_id track_warps
    return $ Timestamp.from_real_time (Score.warp_pos pos warp)

lookup_track_warp :: BlockId -> TrackId -> [TrackWarp] -> Maybe Score.Warp
lookup_track_warp block_id track_id track_warps = case matches of
        [] -> Nothing
        (w:_) -> Just w
    where
    matches =
        [ tw_warp tw | tw <- track_warps, tw_block tw == block_id
        , any (==track_id) (tw_tracks tw)
        ]

make_inverse_tempo_func :: [TrackWarp] -> Transport.InverseTempoFunction
make_inverse_tempo_func track_warps ts = do
    (block_id, track_ids, Just pos) <- track_pos
    return (block_id, [(track_id, pos) | track_id <- track_ids])
    where
    pos = Timestamp.to_real_time ts
    track_pos = [(tw_block tw, tw_tracks tw, unwarp ts (tw_warp tw)) |
            tw <- track_warps, tw_start tw <= pos && pos < tw_end tw]
    unwarp ts warp = Score.unwarp_pos (Timestamp.to_real_time ts) warp

modify :: (Monad m) => (State -> State) -> DeriveT m ()
modify f = (DeriveT . lift) (Monad.State.modify f)

get :: (Monad m) => DeriveT m State
get = (DeriveT . lift) Monad.State.get

gets :: (Monad m) => (State -> a) -> DeriveT m a
gets f = fmap f get

-- | This is a little different from Reader.local because only a portion of
-- the state is used Reader-style, i.e. 'state_track_warps' always collects.
-- TODO split State into dynamically scoped portion and use Reader for that.
local :: (Monad m) => (State -> b) -> (b -> State -> State)
    -> (State -> DeriveT m State) -> DeriveT m a -> DeriveT m a
local from_state to_state modify_state deriver = do
    old <- gets from_state
    new <- modify_state =<< get
    modify (const new)
    deriver `finally` modify (to_state old)

-- | So this is kind of confusing.  When events are created, they are assigned
-- their stack based on the current event_stack, which is set by the
-- with_stack_* functions.  Then, when they are processed, the stack is used
-- to *set* event_stack, which is what 'warn' and 'throw' will look at.
with_event :: (Monad m) => Score.Event -> DeriveT m a -> DeriveT m a
with_event event = local state_stack
    (\old st -> st { state_stack = old })
    (\st -> return $ st { state_stack = Score.event_stack event })

-- ** state access

-- | Lookup a scale_id or throw.
-- TODO merge in the static config scales.
get_scale :: (Monad m) => String -> Pitch.ScaleId -> DeriveT m Pitch.Scale
get_scale caller scale_id = do
    -- Defaulting the scale here means that relative pitch tracks don't need
    -- to mention their scale.
    scale_id <- if scale_id == Pitch.default_scale_id
        then gets (PitchSignal.sig_scale . state_pitch)
        else return scale_id
    maybe (throw (caller ++ ": unknown " ++ show scale_id)) return
        (Map.lookup scale_id Scale.scale_map)

-- ** errors

throw :: (Monad m) => String -> DeriveT m a
throw = throw_srcpos Nothing

throw_srcpos :: (Monad m) => SrcPos.SrcPos -> String -> DeriveT m a
throw_srcpos srcpos msg = do
    stack <- gets state_stack
    context <- gets state_log_context
    Error.throwError (DeriveError srcpos stack (_add_context context msg))

with_msg :: (Monad m) => String -> DeriveT m a -> DeriveT m a
with_msg msg = local state_log_context
    (\old st -> st { state_log_context = old })
    (\st -> return $ st { state_log_context = msg : state_log_context st })

-- | Catch DeriveErrors and convert them into warnings.  If an error is caught,
-- return Nothing, otherwise return Just op's value.
catch_warn :: (Monad m) => (String -> String) -> DeriveT m a
    -> DeriveT m (Maybe a)
catch_warn msg_of op = Error.catchError (fmap Just op) $
    \(DeriveError srcpos stack msg) ->
        Log.warn_stack_srcpos srcpos stack (msg_of msg) >> return Nothing

warn :: (Monad m) => String -> DeriveT m ()
warn = warn_srcpos Nothing

warn_srcpos :: (Monad m) => SrcPos.SrcPos -> String -> DeriveT m ()
warn_srcpos srcpos msg = do
    stack <- gets state_stack
    context <- gets state_log_context
    Log.warn_stack_srcpos srcpos stack (_add_context context msg)

_add_context [] s = s
_add_context context s = Seq.join " / " (reverse context) ++ ": " ++ s

-- ** environment

lookup_val :: forall a m. (TrackLang.Typecheck a, Monad m) =>
    TrackLang.ValName -> DeriveT m (Maybe a)
lookup_val name = do
    environ <- gets state_environ
    let return_type = TrackLang.type_of_val (undefined :: a)
    case TrackLang.lookup_val name environ of
            Left TrackLang.NotFound -> return Nothing
            Left (TrackLang.WrongType typ) ->
                throw $ "lookup_val " ++ show name ++ ": expected "
                    ++ show return_type ++ " but val type is " ++ show typ
            Right v -> return (Just v)

-- | Like 'lookup_val', but throw if the value isn't present.
require_val :: forall a m. (TrackLang.Typecheck a, Monad m) =>
    TrackLang.ValName -> DeriveT m a
require_val name = do
    val <- lookup_val name
    maybe (throw $ "val not present in environ: " ++ show name) return val

put_val :: (Monad m, TrackLang.Typecheck val) => TrackLang.ValName -> val
    -> DeriveT m ()
put_val name val = do
    environ <- insert_environ name val =<< gets state_environ
    modify $ \st -> st { state_environ = environ }

-- | Set the given val dynamically within the given computation.
with_val :: (TrackLang.Typecheck val) => TrackLang.ValName -> val
    -> Deriver a -> Deriver a
with_val name val =
    local state_environ (\old st -> st { state_environ = old }) $ \st -> do
        environ <- insert_environ name val (state_environ st)
        return (st { state_environ = environ })

-- | This is like 'with_val', only it doesn't make any changes to the environ,
-- only restores it on return.
with_local_environ :: (Monad m) => DeriveT m a -> DeriveT m a
with_local_environ =
    local state_environ (\old st -> st { state_environ = old }) return

insert_environ :: (Monad m, TrackLang.Typecheck val) => TrackLang.ValName
    -> val -> TrackLang.Environ -> DeriveT m TrackLang.Environ
insert_environ name val environ =
    case TrackLang.put_val name val environ of
        Left typ -> throw $ "can't set " ++ show name ++ " to " ++ show val
            ++ ", expected " ++ show typ
        Right environ2 -> return environ2

-- *** control

type ControlOp = Signal.Control -> Signal.Control -> Signal.Control
type PitchOp = PitchSignal.PitchSignal -> PitchSignal.Relative
    -> PitchSignal.PitchSignal

-- | Flatten WarpedControls into an unwarped ControlMap.  Put the flattened
-- controls back into the environment so this work isn't duplicated.
unwarped_controls :: (Monad m) =>
    DeriveT m (Score.ControlMap, PitchSignal.PitchSignal)
unwarped_controls = do
    controls <- gets state_controls
    let unwarped = Score.unwarp_controls controls
    pitch <- gets state_pitch
    pitch_warp <- gets state_pitch_warp
    let unwarped_pitch = Score.warp_pitch pitch pitch_warp
    modify $ \st -> st
        { state_controls = Score.warped_controls (Map.toList unwarped)
        , state_pitch = unwarped_pitch
        , state_pitch_warp = Score.id_warp
        }
    return (unwarped, unwarped_pitch)

-- | Return an entire signal.  Remember, signals are in RealTime, so if you
-- want to index them in ScoreTime you will have to call 'score_to_real'.
-- 'control_at' does that for you.
get_control :: (Monad m) => Score.Control -> DeriveT m (Maybe Signal.Control)
get_control cont = do
    controls <- gets state_controls
    return $ Score.unwarped_control cont controls

control_at :: (Monad m) => Score.Control -> Maybe Signal.Y -> ScoreTime
    -> DeriveT m Signal.Y
control_at cont deflt pos = do
    controls <- gets state_controls
    real <- score_to_real pos
    case Score.lookup_control real cont controls of
        Nothing -> maybe
            (throw $ "control_at: not in environment and no default given: "
                ++ show cont) return deflt
        Just y -> return y

pitch_at :: (Monad m) => ScoreTime -> DeriveT m PitchSignal.Y
pitch_at pos = do
    pitches <- gets state_pitch
    warp <- gets state_pitch_warp
    real <- score_to_real pos
    unwarped <- maybe (throw "can't unwarp pos") return $
        Score.unwarp_pos real warp
    return (PitchSignal.at (Types.score_to_real unwarped) pitches)

pitch_degree_at :: (Monad m) => ScoreTime -> DeriveT m Pitch.Degree
pitch_degree_at pos = fmap PitchSignal.y_to_degree (pitch_at pos)

with_control :: (Monad m) =>
    Score.Control -> Signal.Control -> DeriveT m t -> DeriveT m t
with_control cont signal op = do
    controls <- gets state_controls
    -- TODO only revert the specific control
    modify $ \st ->
        st { state_controls = Score.insert_control cont signal controls }
    result <- op
    modify $ \st -> st { state_controls = controls }
    return result

with_control_operator :: (Monad m) => Score.Control -> TrackLang.CallId
    -> Signal.Control -> DeriveT m t -> DeriveT m t
with_control_operator cont c_op signal deriver = do
    op <- lookup_control_op c_op
    with_relative_control cont op signal deriver

with_relative_control :: (Monad m) =>
    Score.Control -> ControlOp -> Signal.Control -> DeriveT m t -> DeriveT m t
with_relative_control cont op signal deriver = do
    controls <- gets state_controls
    let msg = "relative control applied when no absolute control is in scope: "
    case Score.modify_control cont (\old_sig -> op old_sig signal) controls of
        Nothing -> do
            warn (msg ++ show cont)
            deriver
        Just new_controls -> do
            modify $ \st -> st { state_controls = new_controls }
            result <- deriver
            modify $ \st -> st { state_controls = controls }
            return result

with_pitch :: (Monad m) => PitchSignal.PitchSignal -> DeriveT m t -> DeriveT m t
with_pitch signal deriver = do
    old <- gets state_pitch
    modify $ \st -> st { state_pitch = signal }
    result <- deriver
    modify $ \st -> st { state_pitch = old }
    return result

with_constant_pitch :: (Monad m) => Pitch.Degree -> DeriveT m t -> DeriveT m t
with_constant_pitch degree deriver = do
    pitch <- gets state_pitch
    with_pitch (PitchSignal.constant (PitchSignal.sig_scale pitch) degree)
        deriver

with_relative_pitch :: (Monad m) =>
    PitchOp -> PitchSignal.Relative -> DeriveT m t -> DeriveT m t
with_relative_pitch sig_op signal deriver = do
    old <- gets state_pitch
    if old == PitchSignal.empty
        then do
            -- This shouldn't happen normally because of the default pitch.
            warn $ "relative pitch applied when no absolute pitch is in scope"
            deriver
        else do
            modify $ \st -> st { state_pitch = sig_op old signal }
            result <- deriver
            modify $ \st -> st { state_pitch = old }
            return result

with_pitch_operator :: (Monad m) =>
    TrackLang.CallId -> PitchSignal.Relative -> DeriveT m t -> DeriveT m t
with_pitch_operator c_op signal deriver = do
    sig_op <- lookup_pitch_control_op c_op
    with_relative_pitch sig_op signal deriver

-- *** specializations

velocity_at :: (Monad m) => ScoreTime -> DeriveT m Signal.Y
velocity_at = control_at Score.c_velocity (Just default_velocity)

with_velocity :: (Monad m) => Signal.Control -> DeriveT m t -> DeriveT m t
with_velocity = with_control Score.c_velocity

-- *** control ops

lookup_control_op :: (Monad m) => TrackLang.CallId -> DeriveT m ControlOp
lookup_control_op c_op = do
    op_map <- gets state_control_op_map
    maybe (throw ("unknown control op: " ++ show c_op)) return
        (Map.lookup c_op op_map)

-- | Default set of control operators.  Merged at runtime with the static
-- config.  TODO but not yet
default_control_op_map :: Map.Map TrackLang.CallId ControlOp
default_control_op_map = Map.fromList $ map (first TrackLang.Symbol)
    [ ("add", Signal.sig_add)
    , ("sub", Signal.sig_subtract)
    , ("mult", Signal.sig_multiply)
    , ("max", Signal.sig_max)
    , ("min", Signal.sig_min)
    ]

lookup_pitch_control_op :: (Monad m) => TrackLang.CallId -> DeriveT m PitchOp
lookup_pitch_control_op c_op = do
    op_map <- gets state_pitch_op_map
    maybe (throw ("unknown pitch op: " ++ show c_op)) return
        (Map.lookup c_op op_map)

-- | As with 'default_control_op_map', but pitch ops have a different type.
default_pitch_op_map :: Map.Map TrackLang.CallId PitchOp
default_pitch_op_map = Map.fromList $ map (first TrackLang.Symbol)
    [ ("add", PitchSignal.sig_add)
    , ("max", PitchSignal.sig_max)
    , ("min", PitchSignal.sig_min)
    ]

-- lookup_note_call is defined in Derive.Call.Note because it also looks for
-- blocks and returns the block deriver.

lookup_control_call :: (Monad m) => TrackLang.CallId -> DeriveT m ControlCall
lookup_control_call call_id = do
    cmap <- gets state_call_map
    maybe (throw $ "lookup_control_call: unknown " ++ show call_id) return
        (Map.lookup call_id (calls_control cmap))

lookup_pitch_call :: (Monad m) => TrackLang.CallId -> DeriveT m PitchCall
lookup_pitch_call call_id = do
    cmap <- gets state_call_map
    maybe (throw $ "lookup_pitch_call: unknown " ++ show call_id) return
        (Map.lookup call_id (calls_pitch cmap))

-- ** stack

get_current_block_id :: (Monad m) => DeriveT m BlockId
get_current_block_id = do
    stack <- gets state_stack
    case stack of
        [] -> throw "empty state_stack"
        ((block_id, _, _):_) -> return block_id

-- | Make a quick trick block stack.
with_stack_block :: (Monad m) => BlockId -> DeriveT m a -> DeriveT m a
with_stack_block block_id op = do
    modify $ \st ->
        st { state_stack = (block_id, Nothing, Nothing) : state_stack st }
    v <- op
    modify $ \st -> st { state_stack = drop 1 (state_stack st) }
    return v

-- | Make a quick trick track stack.
with_stack_track :: (Monad m) => TrackId -> DeriveT m a -> DeriveT m a
with_stack_track track_id = modify_stack "with_stack_track" $
    \(block_id, _, _) -> (block_id, Just track_id, Nothing)

with_stack_pos :: (Monad m) => ScoreTime -> ScoreTime -> DeriveT m a
    -> DeriveT m a
with_stack_pos pos dur = modify_stack "with_stack_pos" $
    \(block_id, track_id, _) -> (block_id, track_id, Just (start, end))
    where (start, end) = (min pos (pos+dur), max pos (pos+dur))

modify_stack :: (Monad m) => String -> (Warning.StackPos -> Warning.StackPos)
    -> DeriveT m a -> DeriveT m a
modify_stack caller f op = do
    old_stack <- gets state_stack
    new_stack <- case old_stack of
        [] -> throw $ caller ++ ": can't modify empty stack"
        (x:xs) -> return (f x : xs)
    modify $ \st -> st { state_stack = new_stack }
    v <- op
    modify $ \st -> st { state_stack = old_stack }
    return v

-- ** track warps

-- | This doesn't actually take the Warp because it adds this track to the
-- existing \"open\" warp.  This is a hack to assign the same warp to many
-- tracks without having to compare warps to each other, which may be expensive
-- since they can be complicated signals.  Since many tracks should share the
-- same warp, I think grouping them should be a performance win for the
-- playback updater, but I don't know if it's necessary.
--
-- The hack should work as long as 'start_new_warp' is called when the warp is
-- set (d_warp does this).  Otherwise, tracks will be grouped with the wrong
-- tempo, which will cause the playback cursor to not track properly.
add_track_warp :: (Monad m) => TrackId -> DeriveT m ()
add_track_warp track_id = do
    block_id <- get_current_block_id
    track_warps <- gets state_track_warps
    case track_warps of
            -- This happens if the initial block doesn't have a tempo track.
        [] -> start_new_warp >> add_track_warp track_id
        (tw:tws)
            | tw_block tw == block_id -> do
                let new_tws = tw { tw_tracks = track_id : tw_tracks tw } : tws
                modify $ \st -> st { state_track_warps = new_tws }
            -- start_new_warp wasn't called, either by accident or because
            -- this block doesn't have a tempo track.
            | otherwise -> start_new_warp >> add_track_warp track_id

-- | Start a new track warp for the current block_id, as in the stack.
--
-- This must be called for each block, and it must be called after the tempo is
-- warped for that block so it can install the new warp.
start_new_warp :: (Monad m) => DeriveT m ()
start_new_warp = do
    block_id <- get_current_block_id
    start <- score_to_real (ScoreTime 0)
    ui_state <- gets state_ui
    let time_end = either (const (ScoreTime 0)) id $
            State.eval ui_state (State.event_end block_id)
    end <- score_to_real time_end
    modify $ \st ->
        let tw = TrackWarp start end block_id [] (state_warp st)
        in st { state_track_warps = tw : state_track_warps st }

-- * basic derivers

-- ** tempo

-- Tempo is the tempo signal, which is the standard musical definition of
-- tempo: trackpos over time.  Warp is the time warping that the tempo implies,
-- which is integral (1/tempo).

score_to_real :: (Monad m) => ScoreTime -> DeriveT m RealTime
score_to_real pos = do
    warp <- gets state_warp
    return (Score.warp_pos pos warp)

now :: (Monad m) => DeriveT m RealTime
now = score_to_real 0

real_to_score :: (Monad m) => RealTime -> DeriveT m ScoreTime
real_to_score pos = do
    warp <- gets state_warp
    maybe (throw $ "real_to_score out of range: " ++ show pos) return
        (Score.unwarp_pos pos warp)

min_tempo :: Signal.Y
min_tempo = 0.001

d_at :: (Monad m) => ScoreTime -> DeriveT m a -> DeriveT m a
d_at shift = with_warp (Score.shift_warp shift)

d_stretch :: (Monad m) => ScoreTime -> DeriveT m a -> DeriveT m a
d_stretch factor deriver
    -- A stretch of 0 is ok since the deriver may produce no events, or may
    -- work in real time.
    | factor <= 0 = throw $ "stretch <= 0: " ++ show factor
    | otherwise = with_warp (Score.stretch_warp factor) deriver

with_warp :: (Monad m) => (Score.Warp -> Score.Warp) -> DeriveT m a
    -> DeriveT m a
with_warp f deriver = do
    old <- gets state_warp
    modify $ \st -> st { state_warp = f (state_warp st) }
    v <- deriver
    modify $ \st -> st { state_warp = old }
    return v

in_real_time :: (Monad m) => DeriveT m a -> DeriveT m a
in_real_time = with_warp (const Score.id_warp)

d_warp :: (Monad m) => Signal.Warp -> DeriveT m a -> DeriveT m a
d_warp sig deriver = do
    old_warp <- gets state_warp
    -- Log.write $
    --     Signal.log_signal (warp_signal (Score.compose_warp old_warp sig)) $
    --     Log.msg Log.Debug "new warp"
    modify $ \st -> st { state_warp = Score.compose_warp old_warp sig }
    start_new_warp
    result <- deriver
    modify $ \st -> st { state_warp = old_warp }
    return result

-- | Like 'd_warp' but this will also warp controls in the environment.
--
-- 'd_warp' doesn't worp controls at all, but the control track that creates
-- them is warped so they are effectively warped by the surrounding d_warp
-- (TODO continuous control warp might change that).  Subsequent
-- warping inside the d_warp won't affect the controls, so @d_at p d@ won't
-- move the controls along with @d@.
--
-- TODO actually the whole concept is kinda bogus, because it transforms
-- controls after they have already been rendered, which is too late for
-- any kind of abstraction.  See thoughts in doc/tracklang
d_control_warp :: (Monad m) => Signal.Warp -> DeriveT m a -> DeriveT m a
d_control_warp sig deriver = do
    old <- gets state_controls
    old_pitch_warp <- gets state_pitch_warp
    let warped = Score.modify_warps (`Score.compose_warp` sig) old
    let warped_pitch = Score.compose_warp old_pitch_warp sig
    modify $ \st -> st
        { state_controls = warped
        , state_pitch_warp = warped_pitch
        }
    result <- d_warp sig deriver
    modify $ \st -> st
        { state_controls = old
        , state_pitch_warp = old_pitch_warp
        }
    return result

d_control_at :: (Monad m) => ScoreTime -> DeriveT m a -> DeriveT m a
d_control_at shift = with_control_warp (Score.shift_warp shift) . d_at shift

d_control_stretch :: (Monad m) => ScoreTime -> DeriveT m a -> DeriveT m a
d_control_stretch factor =
    with_control_warp (Score.stretch_warp factor) . d_stretch factor

with_control_warp :: (Monad m) => (Score.Warp -> Score.Warp)
    -> DeriveT m a -> DeriveT m a
with_control_warp f deriver = do
    old <- gets state_controls
    old_pitch_warp <- gets state_pitch_warp
    old_pitch <- gets state_pitch
    modify $ \st -> st
        { state_controls = Score.modify_warps f old
        , state_pitch_warp = f old_pitch_warp
        }
    v <- deriver
    -- Restore the signal with the warp, since they may be collapsed.
    -- This will be harder to get wrong once pitch is merged with controls.
    modify $ \st -> st
        { state_controls = old
        , state_pitch_warp = old_pitch_warp
        , state_pitch = old_pitch
        }
    return v


-- | Warp a block with the given deriver with the given signal.
--
-- The track_id passed so that the track that emitted the signal can be marked
-- as having the tempo that it emits, even though it's really derived in real
-- time, so the tempo track's play position will move at the tempo track's
-- tempo.
--
-- The block_id is used to stretch the block to a length of 1, regardless of
-- the tempo.  This means that when the calling block stretches it to the
-- duration of the event it winds up being the right length.  Obviously, this
-- is skipped for the top level block.
--
-- TODO relying on the stack seems a little implicit, would it be better
-- to pass Maybe BlockId or Maybe ScoreTime?
--
-- d_block seems like a better place to do this, but I don't have a local warp
-- yet.  This relies on every block having a d_tempo at the top, but
-- 'add_track_warp' already relies on that so Schema.compile ensures it.
--
-- TODO what to do about blocks with multiple tempo tracks?  I think it would
-- be best to stretch the block to the first one.  I could break out
-- stretch_to_1 and have compile apply it to only the first tempo track.
d_tempo :: (Monad m) => BlockId -> Maybe TrackId -> DeriveT m Signal.Tempo
    -> DeriveT m a -> DeriveT m a
d_tempo block_id maybe_track_id signalm deriver = do
    signal <- signalm
    let warp = tempo_to_warp signal
    top_level <- is_top_level_block
    stretch_to_1 <- if top_level then return id
        else do
            block_dur <- get_block_dur block_id
            real_dur <- with_warp (const (Score.signal_to_warp warp))
                (score_to_real block_dur)
            -- Log.debug $ "dur, global dur "
            --     ++ show (block_id, block_dur, real_dur)
            when (block_dur == 0) $
                throw $ "can't derive a block with zero duration"
            return (d_stretch (1 / Types.real_to_score real_dur))
    -- Optimize for a constant (or missing) tempo.
    let tempo_warp d = if Signal.is_constant signal
            then do
                let tempo = Signal.at 0 signal
                when (tempo <= 0) $
                    throw $ "constant tempo <= 0: " ++ show tempo
                d_stretch (Signal.y_to_score (1 / tempo)) $ start_new_warp >> d
            else d_warp (tempo_to_warp signal) d
    stretch_to_1 $ tempo_warp $ do
        when_just maybe_track_id add_track_warp
        deriver

is_top_level_block :: (Monad m) => DeriveT m Bool
is_top_level_block = do
    stack <- gets state_stack
    return (length stack <= 1)

-- | Sub-derived blocks are stretched according to their length, and this
-- function defines the length of a block.  'event_end' seems the most
-- intuitive, but then you can't make blocks with trailing space.  You can
-- work around it though by appending a comment dummy event.
get_block_dur :: (Monad m) => BlockId -> DeriveT m ScoreTime
get_block_dur block_id = do
    ui_state <- gets state_ui
    either (throw . ("get_block_dur: "++) . show) return
        (State.eval ui_state (State.event_end block_id))

tempo_to_warp :: Signal.Tempo -> Signal.Warp
tempo_to_warp = Signal.integrate Signal.tempo_srate . Signal.map_y (1/)
    . Signal.clip_min min_tempo


-- ** track

-- | This does setup common to all track derivation, namely recording the tempo
-- warp and putting the track in the stack, and then calls the specific track
-- deriver.  This is because every track except tempo tracks should be wrapped
-- with this.  It doesn't actually affect the warp since that's already in
-- the environment.
track_setup :: TrackId -> Deriver d -> Deriver d
track_setup track_id deriver = do
    ignore_tempo <- gets state_ignore_tempo
    unless ignore_tempo (add_track_warp track_id)
    with_local_environ deriver

-- | This is a version of 'track_setup' for the tempo track.  It doesn't record
-- the track warp, see 'd_tempo' for why.
setup_without_warp :: Deriver d -> Deriver d
setup_without_warp deriver = do
    with_local_environ $ with_warp (const Score.id_warp) deriver

-- * utils

-- | Because DeriveT is not a UiStateMonad.
--
-- TODO I suppose it could be, but then I'd be tempted to make
-- a ReadOnlyUiStateMonad.  And I'd have to merge the exceptions.
get_track :: (Monad m) => TrackId -> DeriveT m Track.Track
get_track track_id = get >>= lookup_id track_id . State.state_tracks . state_ui

get_block :: (Monad m) => BlockId -> DeriveT m Block.Block
get_block block_id = get >>= lookup_id block_id . State.state_blocks . state_ui

-- | Lookup @map!key@, throwing if it doesn't exist.
lookup_id key map = case Map.lookup key map of
    Nothing -> throw $ "unknown " ++ show key
    Just val -> return val

-- | General purpose iterator over events.
--
-- It's like 'map_accuml_m' but sets the current event stack before operating
-- on each event, so that 'warn' can use it.  In addition, EventErrors are
-- caught and turned into warnings.  Events that threw aren't included in the
-- output.  An additional function extracts an event, so you can map over
-- things which are not themselves events.
map_events :: (Monad m) =>
    (state -> x -> DeriveT m (a, state))
    -> state -> (x -> Score.Event) -> [x] -> DeriveT m [a]
map_events f state event_of xs =
    fmap Maybe.catMaybes (map_accuml_m apply state xs)
    where
    apply cur_state x = with_event (event_of x) $ do
        val <- catch_warn id (f cur_state x)
        return $ case val of
            Nothing -> (cur_state, Nothing)
            Just (val, next_state) -> (next_state, Just val)

-- | A little more descriptive than ().
data NoState = NoState deriving (Show)

-- ** merge

d_merge :: (Monad m) => DeriveT m Events -> DeriveT m Events
    -> DeriveT m Events
d_merge = liftM2 merge_events

d_merge_list :: (Monad m) => [DeriveT m Events] -> DeriveT m Events
d_merge_list = fmap merge_event_lists . sequence
-- d_merge_list = foldr d_merge (return [])

merge_events :: [Score.Event] -> [Score.Event] -> [Score.Event]
merge_events = Seq.merge_on Score.event_start

merge_event_lists :: [[Score.Event]] -> [Score.Event]
merge_event_lists = Seq.merge_asc_lists Score.event_start

-- | Monoid instance for those who prefer that interface.
instance Monoid.Monoid EventDeriver where
    mempty = empty_events
    mappend = d_merge


-- * negative duration

-- TODO if I wind up going with the postproc route, this should probably become
-- bound to a special toplevel postproc symbol so it can be changed or turned
-- off

-- | Notes with negative duration have an implicit sounding duration which
-- depends on the following note.  Meanwhile (and for the last note of the
-- score), they have this sounding duration.
negative_duration_default :: RealTime
negative_duration_default = 1

-- | Post-process events to replace negative durations with positive ones.
process_negative_durations :: [Score.Event] -> [Score.Event]
process_negative_durations [] = []
process_negative_durations (evt:evts) = evt2 : process_negative_durations evts
    where
    next = find_next evt evts
    dur = calculate_duration (pos_dur evt) (fmap pos_dur next)
    evt2 = if dur == Score.event_duration evt then evt
        else evt { Score.event_duration = dur }
    pos_dur evt = (Score.event_start evt, Score.event_duration evt)

find_next :: Score.Event -> [Score.Event] -> Maybe Score.Event
find_next from = List.find (next_in_track from_stack . Score.event_stack)
    where from_stack = Score.event_stack from

-- | Is the second stack from an event that occurs later on the same track as
-- the first?  This is more complicated than it may seem at first because the
-- second event could come from a different deriver.  So it should look like
-- @same ; same ; bid same / tid same / higher ; *@.
next_in_track :: Warning.Stack -> Warning.Stack -> Bool
next_in_track (s0@(bid0, tid0, r0) : stack0) (s1@(bid1, tid1, r1) : stack1)
    | s0 == s1 = next_in_track stack0 stack1
    | bid0 == bid1 && tid0 == tid1 && r0 `before` r1 = True
    | otherwise = False
    where
    before (Just (s0, _)) (Just (s1, _)) = s0 < s1
    before _ _ = False
next_in_track _ _ = True

calculate_duration :: (RealTime, RealTime) -> Maybe (RealTime, RealTime)
    -> RealTime
calculate_duration (cur_pos, cur_dur) (Just (next_pos, next_dur))
        -- Departing notes are not changed.
    | cur_dur > 0 = cur_dur
        -- Arriving followed by arriving with a rest in between extends to
        -- the arrival of the rest.
    | next_dur <= 0 && rest > 0 = rest
        -- Arriving followed by arriving with no rest, or an arriving note
        -- followed by a departing note will sound until the next note.
    | otherwise = next_pos - cur_pos
    where
    rest = next_pos + next_dur - cur_pos
calculate_duration (_, dur) Nothing
    | dur > 0 = dur
    | otherwise = negative_duration_default
