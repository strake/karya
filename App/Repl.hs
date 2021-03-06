-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{- | Simple repl to talk to seq.

    Type a command to send it to the sequencer.  Everything in
    "Cmd.Repl.Environ" and "Cmd.Repl.Global" is in scope.

    The prompt will have the name of the currently loaded score, and history
    will be written to (and read from) a name.repl file.  Unfortunately you
    have to hit enter to update it if it changed.  TODO bring back async
    notification like before?

    Tab completion should work for function names, and filename completion
    within quotes.

    @:r@ or @:R@ will reload modified modules, but only modify "surface"
    modules, since the GHC API tends to crash if you make it reload too much.
    Maybe crashes if it has to reload something with a C dependency.

    @:h@ or @:H@ will open an editor on the history.  You can find a line, edit
    it, and use ZZ to write it back.
-}
module App.Repl where
import qualified Control.Concurrent.MVar as MVar
import qualified Control.Exception as Exception
import qualified Data.Text as Text
import qualified Data.Text.IO as Text.IO
import qualified Network
import qualified System.Console.Haskeline as Haskeline
import qualified System.Directory as Directory
import qualified System.Environment
import qualified System.Exit as Exit
import qualified System.FilePath as FilePath
import qualified System.IO as IO
import qualified System.Posix.Temp as Posix.Temp
import qualified System.Process as Process

import qualified Util.File as File
import qualified Util.Log as Log
import qualified Util.PPrint as PPrint
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq

import qualified App.Config as Config
import qualified App.ReplProtocol as ReplProtocol
import Global


type Input a = Haskeline.InputT IO a

initial_settings :: Haskeline.Settings IO
initial_settings = Haskeline.defaultSettings
    { Haskeline.historyFile = Just history_suffix
    , Haskeline.autoAddHistory = True
    }

history_suffix :: FilePath
history_suffix = ".repl"

complete :: Network.PortID -> (String, String)
    -> IO (String, [Haskeline.Completion])
complete socket =
    Haskeline.completeQuotedWord (Just '\\') "\"" Haskeline.listFiles
        (complete_identefier socket)
    -- Like ghci, complete filenames within quotes.
    -- TODO or just disable completion?

complete_identefier :: Network.PortID -> Haskeline.CompletionFunc IO
complete_identefier socket =
    Haskeline.completeWord Nothing word_break_chars complete
    where
    complete prefix = do
        words <- ReplProtocol.query_completion socket (txt prefix)
        return $ map (Haskeline.simpleCompletion . untxt) words
    word_break_chars = " \t\n(),;[]`{}!#$%&*+/<=>?@\\^|-~"

type CurrentHistory = MVar.MVar (Maybe FilePath)

main :: IO ()
main = ReplProtocol.initialize $ do
    args <- System.Environment.getArgs
    socket <- case args of
        [] -> return Config.repl_socket
        [fn] -> return $ Network.UnixSocket fn
        _ -> errorIO "usage: repl [ unix-socket ]"
    -- I don't want to see "thread started" logs.
    Log.configure $ \state -> state { Log.state_log_level = Log.Notice }
    liftIO $ putStrLn "^D to quit"
    repl socket $ Haskeline.setComplete (complete socket) initial_settings

repl :: Network.PortID -> Haskeline.Settings IO -> IO ()
repl socket settings = Exception.mask (loop settings)
    where
    loop old_settings restore = do
        let catch Haskeline.Interrupt = do
                putStrLn "interrupted"
                return Continue
        maybe_save_fname <- ReplProtocol.query_save_file socket
        let (connection_error, settings) = case maybe_save_fname of
                Nothing -> (True, old_settings)
                Just fname -> (,) False $ old_settings
                    { Haskeline.historyFile =
                        Just $ fromMaybe "" fname <> history_suffix
                    }
        status <- Exception.handle catch $ restore $
            Haskeline.runInputT settings $ Haskeline.withInterrupt $
            read_eval_print socket connection_error
                (Haskeline.historyFile settings)
        case status of
            Continue -> loop settings restore
            Command cmd -> do
                status <- liftIO $ send_command socket cmd
                case status of
                    Continue -> loop settings restore
                    Command cmd -> do
                        -- Or maybe I should just keep having this conversation?
                        putStrLn $ "two Commands in a row: " <> show cmd
                        loop settings restore
                    Quit -> return ()
            Quit -> return ()
    read_eval_print socket connection_error history =
        maybe (return Quit) (liftIO . eval socket history)
            =<< get_input connection_error history

eval :: Network.PortID -> Maybe FilePath -> Text -> IO Status
eval socket maybe_history expr
    | Text.strip expr `elem` [":h", ":H"] = case maybe_history of
        Nothing -> putStrLn "no history to edit" >> return Continue
        Just history ->
            maybe (return Continue) (send_command socket) =<< edit_line history
    | otherwise = send_command socket expr

send_command :: Network.PortID -> Text -> IO Status
send_command socket expr
    | Text.null expr = return Continue
    | otherwise = do
        result <- ReplProtocol.query_cmd socket (Text.strip expr)
        result <- print_logs result
        handle_result result

handle_result :: ReplProtocol.Result -> IO Status
handle_result (ReplProtocol.Raw text) = do
    unless (Text.null (Text.strip text)) $
        Text.IO.putStrLn (Text.stripEnd text)
    return Continue
handle_result (ReplProtocol.Format text) = do
    unless (Text.null (Text.strip text)) $
        putStr $ PPrint.format_str $ untxt text
    return Continue
handle_result (ReplProtocol.Edit editor) = edit editor >> return Continue

print_logs :: ReplProtocol.CmdResult -> IO ReplProtocol.Result
print_logs (ReplProtocol.CmdResult val logs_) = do
    -- Filter Debug logs, otherwise I get spammed with cache msgs.
    let logs = filter ((>Log.Debug) . Log.msg_priority) $
            ReplProtocol.abbreviate_package_loads logs_
    unless (null logs) $ do
        putStrLn "Logs:"
        mapM_ Pretty.pprint logs
        putChar '\n'
    return val

get_input :: Bool -> Maybe FilePath -> Input (Maybe Text)
get_input connection_error history =
    fmap (Text.strip . txt) <$>
        Haskeline.getInputLine (prompt connection_error history)

data Status = Continue
    -- | Skip the next prompt and send this as a QCommand.
    | Command !Text
    -- | Blow this popsicle stand.
    | Quit deriving (Show)

-- | Colorize the prompt to make it stand out.
prompt :: Bool -> Maybe FilePath -> String
prompt connection_error maybe_save =
    mconcat [save,  color_bg,  stx,  "入",  plain_bg,  stx,  " "]
    where
    color_bg = if connection_error then red_bg else cyan_bg
    save = maybe "" (fst . Seq.drop_suffix ".repl" . FilePath.takeFileName)
        maybe_save
    -- The trailing \STX tells haskeline this is a control sequence, from
    -- http://trac.haskell.org/haskeline/wiki/ControlSequencesInPrompt
    stx = "\STX"

cyan_bg :: String
cyan_bg = "\ESC[46m"

red_bg :: String
red_bg = "\ESC[41m"

plain_bg :: String
plain_bg = "\ESC[39;49m"


-- * editor

-- | Open an editor as requested by 'ReplProtocol.Editor'.
edit :: ReplProtocol.Editor -> IO ()
edit (ReplProtocol.Editor file line mb_on_save mb_on_send) = case file of
    ReplProtocol.Text content -> with_temp "repl-" content edit_file
    ReplProtocol.FileName fname -> edit_file fname
    where
    editor = "vi"
    edit_file fname = do
        let args = commands ++ ["+" <> show line, fname]
        ok <- wait_for_command editor args
        when ok $ whenJust mb_on_save $ \on_save ->
            send_file fname on_save
    commands = concatMap (\x -> ["-c", x]) $ concat
        [ ["source vim-functions.vim"]
        , case file of
            -- I don't know that it's ky syntax, but so far ReplProtocol.Text
            -- always is.
            ReplProtocol.Text {} -> ["source ky-syntax.vim"]
            _ -> []
        , save_cmd
        , send_cmd
        ]

    save_cmd = case mb_on_save of
        Just on_save -> ["nmap gz :call Send('" <> untxt on_save <> "')<cr>"]
        Nothing -> []
    send_cmd = case mb_on_send of
        Just on_send -> ["nmap gs :call Send('" <> untxt on_send <> "')<cr>"]
        Nothing -> []

send_file :: FilePath -> Text -> IO ()
send_file fname cmd = do
    -- The 'send' cmd substitutes stdin for %s.
    content <- if "%s" `Text.isInfixOf` cmd
        -- vim will add a final newline.
        then Text.stripEnd <$> Text.IO.readFile fname
        else return ""
    stdout <- Process.readProcess "build/opt/send" [untxt cmd]
        (untxt content)
    unless (null stdout) $
        putStrLn $ "send: " <> stdout

-- | Run the action with a temp file, and delete it afterwards.
with_temp :: FilePath -> Text -> (FilePath -> IO a) -> IO a
with_temp prefix contents action = do
    (path, hdl) <- Posix.Temp.mkstemp prefix
    Text.IO.hPutStr hdl contents
    Text.IO.hPutStr hdl "\n" -- otherwise vim doesn't like no final newline
    IO.hClose hdl
    action path
        `Exception.finally` File.ignoreEnoent (Directory.removeFile path)

-- | Open the given file, and return the selected line.
edit_line :: FilePath -> IO (Maybe Text)
edit_line fname = with_temp "repl-edit-history-" "" $ \tmp -> do
    let cmdline =
            [ "-c", "nmap ZZ :set write \\| .w! " <> tmp <> " \\| q!<cr>"
            , "-c", "set nowrite"
            , fname
            ]
    ok <- wait_for_command "vi" cmdline
    if ok
        then Just . Text.strip <$> Text.IO.readFile tmp
        else return Nothing

wait_for_command :: FilePath -> [String] -> IO Bool
wait_for_command cmd args = do
    pid <- Process.spawnProcess cmd args
    code <- Process.waitForProcess pid
    case code of
        Exit.ExitSuccess -> return True
        Exit.ExitFailure code -> do
            -- Maybe the binary wasn't found, but vim seems to return
            -- 1 unpredictably.
            Log.warn $ "non-zero exit code from "
                <> showt (cmd : args) <> ": " <> showt code
            return False
