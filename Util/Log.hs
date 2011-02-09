{-# LANGUAGE GeneralizedNewtypeDeriving, DeriveDataTypeable #-}
{- | Functions for logging.

    Log msgs are used to report everything from errors and debug msgs to status
    reports.  They are collected in a central place that writes them to a file
    in a machine-readable serialized format.
-}

module Util.Log (
    configure
    -- * msgs
    , Msg(..), msg_string, Prio(..), State(..)
    , msg, msg_srcpos, uninitialized_msg, uninitialized_msg_srcpos
    , timer, debug, notice, warn, error
    , is_first_timer, first_timer_prefix
    , timer_srcpos, debug_srcpos, notice_srcpos, warn_srcpos, error_srcpos
    , debug_stack, notice_stack, warn_stack, error_stack
    , debug_stack_srcpos, notice_stack_srcpos, warn_stack_srcpos
        , error_stack_srcpos
    , trace_logs
    -- * LogT monad
    , LogMonad(..)
    , LogT, run
    -- * LazyLogT monad
    , Msgs, empty_msgs
    , LazyLogT, run_lazy
    -- * serialization
    , format_msg
    , serialize_msg, deserialize_msg
) where
import Prelude hiding (error, log)
import qualified Control.Concurrent.MVar as MVar
import qualified Control.DeepSeq as DeepSeq
import qualified Control.Exception as Exception
import Control.Monad
import qualified Control.Monad.Error as Error
import qualified Control.Monad.Trans as Trans
import qualified Control.Monad.Writer.Lazy as Writer
import qualified Data.Generics as Generics
import qualified Data.Text as Text
import qualified Data.Time as Time
import qualified Debug.Trace as Trace
import qualified System.IO as IO
import qualified System.IO.Unsafe  as Unsafe
import Text.Printf (printf)

import qualified Util.AppendList as AppendList
import qualified Util.Logger as Logger
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq
import qualified Util.SrcPos as SrcPos

-- This import is a little iffy because Util shouldn't be importing from
-- elsewhere, but the stack uses TrackIds.  UI doesn't use the logging, so
-- I'm safe for now...
import qualified Derive.Stack as Stack


data Msg = Msg {
    msg_date :: !Time.UTCTime
    , msg_caller :: !SrcPos.SrcPos
    , msg_prio :: !Prio
    -- | Msgs which are logged from the deriver may record the position in the
    -- schema and event being processed.
    , msg_stack :: !(Maybe Stack.Stack)
    -- | Free form text for humans.
    , msg_text  :: !Text.Text
    -- | Attach some typed data.  Data.Dynamic would be more generic, but
    -- I can't think of anything I'd use it for other than signals.
    , msg_signal :: ![(Double, Double)]
    } deriving (Eq, Show, Read, Generics.Typeable)

instance DeepSeq.NFData Msg where
    rnf (Msg {}) = ()

msg_string :: Msg -> String
msg_string = Text.unpack . msg_text

instance Pretty.Pretty Msg where
    pretty = format_msg

-- | Pure code can't give a date, but making msg_date Maybe makes it awkward
-- for everyone who processes Msgs, so cheat with this.
no_date_yet :: Time.UTCTime
no_date_yet = Time.UTCTime (Time.ModifiedJulianDay 0) 0

-- | Logging state.  Don't log if a handle is Nothing.
data State = State {
    state_log_hdl :: Maybe IO.Handle
    , state_log_level :: Prio
    -- | Function to format a Msg for output.
    -- TODO it could be Text, but there's not much point as long as the
    -- default serialize and deserialize is show and read.
    , state_log_formatter :: Msg -> String
    }

initial_state :: State
initial_state = State (Just IO.stderr) Debug format_msg

global_state :: MVar.MVar State
{-# NOINLINE global_state #-}
global_state = Unsafe.unsafePerformIO (MVar.newMVar initial_state)

-- | Configure the logging system by modifying its internal state.
-- Return the old state so you can restore it later.
configure :: (State -> State) -> IO State
configure f = MVar.modifyMVar global_state $ \old -> do
    let new = f old
    -- This seems like a bit of a hack, but it does seem like the hdl should be
    -- in line mode.
    case state_log_hdl new of
        Just hdl -> IO.hSetBuffering hdl IO.LineBuffering
        _ -> return ()
    return (new, new)

data Prio =
    -- | Generated everywhere, to figure out where hangs are happening.  Should
    -- only be on when debugging performance.  They only really work in
    -- explicitly sequenced MonadIO code.
    Timer
    -- | Lots of msgs produced by code level.  Users don't look at this during
    -- normal use, but can be useful for debugging.
    | Debug
    -- | Informational msgs that the user will want to see.  Progress messages
    -- in e.g. derivation and play status are included here.
    | Notice
    -- | Something went wrong in e.g. derivation.  User definitely wants to see
    -- this.
    | Warn
    -- | Code error in the app, which may quit after printing this.
    | Error
    deriving (Show, Enum, Eq, Ord, Read)

-- | Create a msg with the give prio and text.
msg_srcpos :: (LogMonad m) => SrcPos.SrcPos -> Prio -> String -> m Msg
msg_srcpos srcpos prio text = make_msg srcpos prio Nothing text

msg :: (LogMonad m) => Prio -> String -> m Msg
msg prio = msg_srcpos Nothing prio

-- | Create a msg without initializing it, so it doesn't have to be in
-- LogMonad.
uninitialized_msg :: Prio -> Maybe Stack.Stack -> String -> Msg
uninitialized_msg = uninitialized_msg_srcpos Nothing

-- | Create a msg without initializing it.
uninitialized_msg_srcpos :: SrcPos.SrcPos -> Prio -> Maybe Stack.Stack -> String
    -> Msg
uninitialized_msg_srcpos srcpos prio stack text =
    Msg no_date_yet srcpos prio stack (Text.pack text) []

-- | This is the main way to construct a Msg since 'initialize_msg' is called.
make_msg :: (LogMonad m) =>
    SrcPos.SrcPos -> Prio -> Maybe Stack.Stack -> String -> m Msg
make_msg srcpos prio stack text =
    initialize_msg (uninitialized_msg_srcpos srcpos prio stack text)

log :: (LogMonad m) => Prio -> SrcPos.SrcPos -> String -> m ()
log prio srcpos text = write =<< make_msg srcpos prio Nothing text

log_stack :: (LogMonad m) => Prio -> SrcPos.SrcPos -> Stack.Stack -> String
    -> m ()
log_stack prio srcpos stack text =
    write =<< make_msg srcpos prio (Just stack) text

timer_srcpos, debug_srcpos, notice_srcpos, warn_srcpos, error_srcpos
    :: (LogMonad m) => SrcPos.SrcPos -> String -> m ()
timer_srcpos = log Timer
debug_srcpos = log Debug
notice_srcpos = log Notice
warn_srcpos = log Warn
error_srcpos = log Error

timer, debug, notice, warn, error :: (LogMonad m) => String -> m ()
timer = timer_srcpos Nothing
debug = debug_srcpos Nothing
notice = notice_srcpos Nothing
warn = warn_srcpos Nothing
error = error_srcpos Nothing

is_first_timer :: Msg -> Bool
is_first_timer (Msg { msg_prio = Timer, msg_text = text }) =
    Text.pack first_timer_prefix `Text.isPrefixOf` text
is_first_timer _ = False

-- | Prepend to a timer msg after an expected delay, like waiting on input.
first_timer_prefix :: String
first_timer_prefix = "first_timer: "

-- Yay permutation game.  I could probably do a typeclass trick to make 'stack'
-- an optional arg, but I think I'd wind up with all the same boilerplate here.
debug_stack_srcpos, notice_stack_srcpos, warn_stack_srcpos, error_stack_srcpos
    :: (LogMonad m) => SrcPos.SrcPos -> Stack.Stack -> String -> m ()
debug_stack_srcpos = log_stack Debug
notice_stack_srcpos = log_stack Notice
warn_stack_srcpos = log_stack Warn
error_stack_srcpos = log_stack Error

debug_stack, notice_stack, warn_stack, error_stack :: (LogMonad m) =>
    Stack.Stack -> String -> m ()
debug_stack = debug_stack_srcpos Nothing
notice_stack = notice_stack_srcpos Nothing
warn_stack = warn_stack_srcpos Nothing
error_stack = error_stack_srcpos Nothing

-- | Write log msgs with 'trace', for debugging.
trace_logs :: [Msg] -> a -> a
trace_logs logs val
    | null logs = val
    | otherwise = Trace.trace
        (Seq.rdrop_while (=='\n') $ unlines $ "\tlogged:" : map format_msg logs)
        val

-- * LogT

class Monad m => LogMonad m where
    write :: Msg -> m ()

    -- | An instance for whatever monad you're using can use this to add some
    -- custom data, like stack information.
    initialize_msg :: Msg -> m Msg
    initialize_msg = return

instance LogMonad IO where
    write log_msg = do
        -- This is also done by 'initialize_msg', but if the msg was created
        -- outside of IO, it won't have had IO's 'initialize_msg' run on it.
        MVar.withMVar global_state $ \(State m_hdl prio formatter) ->
            case m_hdl of
                Just hdl | prio <= msg_prio log_msg -> do
                    -- Go to a little bother to only run 'add_time' for msgs
                    -- that are actually logged.
                    log_msg <- add_time log_msg
                    IO.hPutStrLn hdl (formatter log_msg)
                _ -> return ()
        when (msg_prio log_msg == Error) $ do
            log_msg <- add_time log_msg
            IO.hPutStrLn IO.stderr (format_msg log_msg)

-- | Format a msg in a nice user readable way.
format_msg :: Msg -> String
format_msg (Msg { msg_date = _date, msg_caller = srcpos, msg_prio = prio
        , msg_text = text, msg_stack = stack }) =
    log_msg ++ maybe "" ((' ':) . Pretty.pretty) stack
    where
    prio_stars Timer = "-"
    prio_stars prio = replicate (fromEnum prio) '*'
    log_msg = printf "%-4s %s - %s"
        (prio_stars prio) (SrcPos.show_srcpos srcpos) (Text.unpack text)

-- | Add a time to the msg if it doesn't already have one.  Msgs can be logged
-- outside of IO, so they don't get a date until they are written.
add_time :: Msg -> IO Msg
add_time log_msg
    | msg_date log_msg == no_date_yet = do
        utc <- Time.getCurrentTime
        return $ log_msg { msg_date = utc }
    | otherwise = return log_msg

instance (Monad m) => LogMonad (LogT m) where
    write log_msg = write_msg log_msg

write_msg :: Monad m => Msg -> LogT m ()
write_msg = LogT . Logger.log

type LogM m = Logger.LoggerT Msg m
newtype LogT m a = LogT (LogM m a)
    deriving (Functor, Monad, Trans.MonadIO, Trans.MonadTrans,
        Error.MonadError e)
run_log_t (LogT x) = x

run :: Monad m => LogT m a -> m (a, [Msg])
run = Logger.run . run_log_t

-- * LazyLogT

newtype LazyLogT m a = LazyLogT (Writer.WriterT [Msg] m a)
    deriving (Functor, Monad, Trans.MonadIO, Trans.MonadTrans,
        Error.MonadError e)

instance (Monad m) => LogMonad (LazyLogT m) where
    write = LazyLogT . Writer.tell . (:[])

run_lazy :: (Monad m) => LazyLogT m a -> m (a, [Msg])
run_lazy (LazyLogT m) = Writer.runWriterT m

-- * serialize

serialize_msg :: Msg -> String
serialize_msg = show

deserialize_msg :: String -> IO (Either Exception.SomeException Msg)
deserialize_msg log_msg = Exception.try (readIO log_msg)
