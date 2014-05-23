-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Utilities to deal with processes.
module Util.Process where
import qualified Control.Concurrent as Concurrent
import qualified Control.Concurrent.MVar as MVar
import qualified Control.Exception as Exception

import qualified Data.ByteString as ByteString
import qualified System.Exit as Exit
import qualified System.IO as IO
import qualified System.IO.Error as IO.Error
import qualified System.Posix as Posix
import qualified System.Process as Process

import qualified Util.Log as Log


-- | Similar to 'Process.readProcessWithExitCode' but return ByteStrings
-- instead of String.
readProcessWithExitCode :: Maybe [(String, String)] -> FilePath -> [String]
    -> ByteString.ByteString
    -> IO (Exit.ExitCode, ByteString.ByteString, ByteString.ByteString)
readProcessWithExitCode env cmd args stdin = do
    (Just inh, Just outh, Just errh, pid) <-
        Process.createProcess (Process.proc cmd args)
            { Process.env = env
            , Process.std_in = Process.CreatePipe
            , Process.std_out = Process.CreatePipe
            , Process.std_err = Process.CreatePipe
            , Process.close_fds = True
            }
    outMVar <- MVar.newEmptyMVar
    errMVar <- MVar.newEmptyMVar
    Concurrent.forkIO $ MVar.putMVar outMVar =<< ByteString.hGetContents outh
    Concurrent.forkIO $ MVar.putMVar errMVar =<< ByteString.hGetContents errh
    Concurrent.forkIO $ ByteString.hPut inh stdin >> IO.hClose inh
    out <- MVar.takeMVar outMVar
    err <- MVar.takeMVar errMVar
    IO.hClose outh
    IO.hClose errh
    ex <- Process.waitForProcess pid
    return (ex, out, err)

-- | Like 'Process.createProcess', but log if the binary wasn't found or
-- failed.
logged :: Process.CreateProcess -> IO (Maybe IO.Handle,
       Maybe IO.Handle, Maybe IO.Handle, Process.ProcessHandle)
logged create = do
    r@(_, _, _, pid) <- Process.createProcess create
    Concurrent.forkIO $ do
        code <- Process.waitForProcess pid
        case code of
            Exit.ExitFailure c -> Log.error $
                "subprocess " ++ show (binaryOf create) ++ " failed: "
                ++ if c == 127 then "binary not found" else show c
            _ -> return ()
    return r
    where
    binaryOf create = case Process.cmdspec create of
        Process.RawCommand fn _ -> fn
        Process.ShellCommand cmd -> takeWhile (/=' ') cmd

isAlive :: Posix.ProcessID -> IO Bool
isAlive pid = (Posix.signalProcess Posix.nullSignal pid >> return True)
    `Exception.catch` (return . not . IO.Error.isDoesNotExistError)

commandName :: Posix.ProcessID -> IO (Maybe String)
commandName pid = do
    -- Ignore the exit code, because ps -p returns 1 when the pid doesn't
    -- exist.
    (_, output, _) <- Process.readProcessWithExitCode
        "ps" ["-p", show pid, "-o", "comm"] ""
    return $ case lines output of
        [_, cmd] -> Just cmd
        _ -> Nothing

exit :: Int -> IO a
exit 0 = Exit.exitSuccess
exit n = Exit.exitWith $ Exit.ExitFailure n
