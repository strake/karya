{-# LANGUAGE OverloadedStrings #-}
module Shake.HsDeps (importsOf, transitiveImportsOf) where
import Control.Applicative ((<$>))
import qualified Control.Concurrent as Concurrent
import qualified Control.Exception as Exception
import qualified Control.Monad.Trans as Trans

import qualified Data.ByteString.Char8 as B
import qualified Data.Maybe as Maybe
import qualified Data.Set as Set

import qualified Development.Shake as Shake
import qualified System.Directory as Directory
import qualified System.Exit as Exit
import qualified System.IO as IO
import qualified System.Process as Process

import qualified Shake.Util as Util


type ModuleName = B.ByteString

-- | Find files of modules this module imports, in the form A/B.hs or A/B.hsc.
-- Paths that don't exist are assumed to be package imports and are omitted.
importsOf :: Maybe [String] -> FilePath -> Shake.Action [FilePath]
importsOf cppFlags fn = Shake.need [fn] >> Trans.liftIO (importsOf_ cppFlags fn)

importsOf_ :: Maybe [String] -- ^ If Just, first run CPP with these flags.
    -> FilePath -> IO [FilePath]
importsOf_ cppFlags fn = do
    imports <- withCppFile cppFlags fn readImportBlock
    Maybe.catMaybes <$> mapM fileOf (parseImports imports)

-- | Like 'importsOf' but transitive.  Includes the given module.
--
-- TODO Technically I should run CPP on the output of hsc2hs, which means
-- this should map the module names to the appropriate .hs and 'need' it.
-- Otherwise the '#include' that belongs to hsc2hs will get processed by CPP.
transitiveImportsOf :: (FilePath -> Maybe [String]) -> FilePath
    -> Shake.Action [FilePath]
transitiveImportsOf cppFlagsOf fn =
    Shake.need [fn] >> Trans.liftIO (transitiveImportsOf_ cppFlagsOf fn)

transitiveImportsOf_ :: (FilePath -> Maybe [String]) -> FilePath
    -> IO [FilePath]
transitiveImportsOf_ cppFlagsOf fn = go Set.empty [fn]
    where
    go checked (fn:fns)
        | fn `Set.member` checked = go checked fns
        | otherwise = do
            imports <- importsOf_ (cppFlagsOf fn) fn
            let checked' = Set.insert fn checked
            go checked' (fns ++ filter (`Set.notMember` checked') imports)
    go checked [] = return $ Set.toList checked

fileOf :: ModuleName -> IO (Maybe FilePath)
fileOf mod =
    Util.ifM (Directory.doesFileExist fn) (return (Just fn)) $
    Util.ifM (Directory.doesFileExist (fn ++ "c"))
        (return (Just (fn ++ "c"))) (return Nothing)
    where
    fn = B.unpack $ B.map slash mod `B.append` ".hs"
    slash c = if c == '.' then '/' else c

parseImports :: [B.ByteString] -> [ModuleName]
parseImports = Maybe.mapMaybe (parse . B.words)
    where
    parse (w1:w2:w3:_) | (w1, w2) == ("import", "qualified") = Just w3
    parse (w1:w2:_) | w1 == "import" = Just w2
    parse _ = Nothing

readImportBlock :: IO.Handle -> IO [B.ByteString]
readImportBlock hdl = header
    where
    header = read [] $ \line ->
        if isImport line then imports [line] else header
    imports accum = read accum $ \line ->
        if postImports line then return accum else imports (line:accum)
    isImport = ("import " `B.isPrefixOf`)
    -- Icky, but if I see a type signature, I'm probably out of the imports.
    postImports = (" :: " `B.isInfixOf`)
    read accum rest = do
        eof <- IO.hIsEOF hdl
        if eof then return accum else rest =<< B.hGetLine hdl

withCppFile :: Maybe [String] -> FilePath -> (IO.Handle -> IO a) -> IO a
withCppFile Nothing fn = withFile fn
withCppFile (Just flags) fn = Exception.bracket open IO.hClose
    where
    open = do
        (_, Just stdout, _, _) <- loggedProcess $
            (Process.proc "cpp" (flags ++ [fn]))
                { Process.std_out = Process.CreatePipe }
        return stdout


-- * util

withFile :: FilePath -> (IO.Handle -> IO a) -> IO a
withFile fn = Exception.bracket (IO.openFile fn IO.ReadMode) IO.hClose

-- | Like 'Process.createProcess', but actually report when the binary isn't
-- found.
loggedProcess :: Process.CreateProcess -> IO (Maybe IO.Handle,
       Maybe IO.Handle, Maybe IO.Handle, Process.ProcessHandle)
loggedProcess create = do
    r@(_, _, _, pid) <- Process.createProcess create
    Concurrent.forkIO $ do
        code <- Process.waitForProcess pid
        case code of
            Exit.ExitFailure c -> IO.hPutStrLn IO.stderr $
                "subprocess " ++ show (binaryOf create) ++ " failed: "
                ++ if c == 127 then "binary not found" else show c
            _ -> return ()
    return r
    where
    binaryOf create = case Process.cmdspec create of
        Process.RawCommand fn _ -> fn
        Process.ShellCommand cmd -> fst $ break (==' ') cmd
