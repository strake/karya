-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Util.Thread (
    start, startLogged
    , Seconds, delay
    , timeout
    -- * Flag
    , Flag, flag, set, wait, poll
    -- * timing
    , force, timeAction, timeActionText, printTimer, currentCPU
) where
import qualified Control.Concurrent as Concurrent
import qualified Control.Concurrent.STM as STM
import qualified Control.DeepSeq as DeepSeq
import qualified Control.Exception as Exception
import qualified Control.Monad.Trans as Trans

import Data.Monoid ((<>))
import qualified Data.Text as Text
import qualified Data.Text.IO as Text.IO
import qualified Data.Time as Time

import qualified GHC.Conc as Conc
import qualified System.CPUTime as CPUTime
import qualified System.IO as IO
import qualified System.Timeout as Timeout

import qualified Text.Printf as Printf

import qualified Util.Log as Log


-- | Start a noisy thread that will log when it starts and stops, and warn if
-- it dies from an exception.
startLogged :: String -> IO () -> IO Concurrent.ThreadId
startLogged name thread = do
    threadId <- Concurrent.myThreadId
    Conc.labelThread threadId name
    let threadName = Text.pack $ show threadId ++ " " ++ name ++ ": "
    Log.debug $ threadName <> "started"
    Concurrent.forkFinally thread $ \result -> case result of
        Right () -> Log.debug $ threadName <> "completed"
        Left err -> Log.warn $ threadName <> "died: "
            <> Text.pack (show (err :: Exception.SomeException))

start :: IO () -> IO Concurrent.ThreadId
start = Concurrent.forkIO

-- | This is just NominalDiffTime, but with a name I might remember.
type Seconds = Time.NominalDiffTime

-- | Delay in seconds.
delay :: Seconds -> IO ()
delay = Concurrent.threadDelay . toUsec

timeout :: Seconds -> IO a -> IO (Maybe a)
timeout = Timeout.timeout . toUsec

toUsec :: Seconds -> Int
toUsec = round . (*1000000)

-- * Flag

-- | A Flag starts False, and can eventually become True.  It never goes back
-- to False again.
newtype Flag = Flag (STM.TVar Bool)

instance Show Flag where show _ = "((Flag))"

flag :: IO Flag
flag = Flag <$> STM.newTVarIO False

set :: Flag -> IO ()
set (Flag var) = STM.atomically $ STM.writeTVar var True

-- | Wait a finite amount of time for the flag to become true.
poll :: Seconds -> Flag -> IO Bool
poll time (Flag var)
    | time <= 0 = STM.readTVarIO var
    | otherwise = maybe False (const True) <$> timeout time (wait (Flag var))

-- | Wait until the flag becomes true.
wait :: Flag -> IO ()
wait (Flag var) = STM.atomically $ do
    val <- STM.readTVar var
    if val then return () else STM.retry

-- * timing

force :: DeepSeq.NFData a => a -> IO ()
force x = Exception.evaluate (DeepSeq.rnf x)

-- | Time an IO action in CPU and wall seconds.  Technically not thread
-- related, but I don't have a better place at the moment.
timeAction :: Trans.MonadIO m
    => m a -> m (a, Seconds, Seconds) -- ^ (a, cpu, wall)
timeAction action = do
    startCpu <- Trans.liftIO CPUTime.getCPUTime
    start <- Trans.liftIO Time.getCurrentTime
    !val <- action
    endCpu <- Trans.liftIO CPUTime.getCPUTime
    end <- Trans.liftIO Time.getCurrentTime
    let elapsed = end `Time.diffUTCTime` start
    return (val, cpuToSec (endCpu - startCpu), elapsed)

-- | Like 'timeAction', but return a Text msg instead of the values.
timeActionText :: Trans.MonadIO m => m a -> m (a, Text.Text)
timeActionText = fmap fmt . timeAction
    where
    fmt (val, cpu, wall) = (,) val $ Text.pack $ Printf.printf
        "%.2f cpu / %.2fs" (toSecs cpu) (toSecs wall)

cpuToSec :: Integer -> Seconds
cpuToSec s = fromIntegral s / fromIntegral (10^12)

printTimer :: Text.Text -> (a -> String) -> IO a -> IO a
printTimer msg showVal action = do
    Text.IO.putStr $ msg <> " - "
    IO.hFlush IO.stdout
    result <- Exception.try $ timeActionText $ do
        !val <- action
        return val
    case result of
        Right (val, msg) -> do
            Text.IO.putStrLn $
                "time: " <> msg <> " - " <> Text.pack (showVal val)
            return val
        Left (exc :: Exception.SomeException) -> do
            -- Complete the line so the exception doesn't interrupt it.  This
            -- is important if it's a 'failure' line!
            putStrLn $ "threw exception: " <> show exc
            Exception.throwIO exc

currentCPU :: IO Seconds
currentCPU = cpuToSec <$> CPUTime.getCPUTime

toSecs :: Seconds -> Double
toSecs = realToFrac
