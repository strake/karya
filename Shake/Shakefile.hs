-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE FlexibleContexts, ViewPatterns #-}
{-# LANGUAGE DeriveDataTypeable, GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{- | Shakefile for seq and associated binaries.

    TODO

    - askOracle isn't working like I think it should, why does it only
    rebuild test_block.cc when I change fltk version?

    - If I update build/test/RunTests.hs, it gets regenerated, even though
    it's newer than everything else.  Why?
    Also, if I update generate_run_tests.py it doesn't rebuild anything.
-}
module Shake.Shakefile where
import Control.Applicative ((<$>))
import qualified Control.DeepSeq as DeepSeq
import qualified Control.Exception as Exception
import Control.Monad
import qualified Control.Monad.Trans as Trans

import qualified Data.Binary as Binary
import qualified Data.Char as Char
import qualified Data.Generics as Generics
import qualified Data.Hashable as Hashable
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Monoid as Monoid
import Data.Monoid (mempty, (<>))

import qualified Development.Shake as Shake
import Development.Shake ((?==), (?>), (?>>), (*>), need)
import qualified System.Directory as Directory
import qualified System.Environment as Environment
import qualified System.FilePath as FilePath
import System.FilePath ((</>))
import qualified System.IO as IO
import qualified System.Info
import qualified System.Process as Process

import qualified Util.PPrint as PPrint
import qualified Shake.CcDeps as CcDeps
import qualified Shake.HsDeps as HsDeps
import qualified Shake.Progress as Progress
import qualified Shake.Util as Util
import Shake.Util (system)


-- * config

-- | If true, link in the EKG library for realtime monitoring.
useEkg :: Bool
useEkg = True

-- Static constants.
build = "build"
fltkConfig = "/usr/local/src/fltk-1.3/fltk-config"
ghcBinary = "ghc"
hspp = modeToDir Opt </> "hspp"

defaultOptions :: Shake.ShakeOptions
defaultOptions = Shake.shakeOptions
    { Shake.shakeFiles = build </> "shake"
    , Shake.shakeVerbosity = Shake.Quiet
    , Shake.shakeReport = Just $ build </> "report.html"
    , Shake.shakeProgress = Progress.report
    }

data Config = Config {
    buildDir :: FilePath
    , hscDir :: FilePath
    , ghcLib :: FilePath
    , fltkVersion :: String
    , configFlags :: Flags
    } deriving (Show)

-- | Root of .o and .hi hierarchy.
oDir :: Config -> FilePath
oDir = (</> "obj") . buildDir

docDir :: FilePath
docDir = build </> "doc"

-- * flags

data Flags = Flags {
    -- | -D flags.
    define :: [String]
    -- | Linker flags to link in whatever MIDI driver we are using today.
    -- There should be corresponding flags in 'define' to enable said driver.
    , midiLibs :: [String]
    -- | There's one global list of include dirs, for both haskell and C++.
    -- Technically they don't all need the same dirs, but it doesn't hurt to
    -- have unneeded ones.
    , cInclude :: [String]

    -- | Flags for g++.  This is the complete list and includes the 'define's
    -- and 'cInclude's.
    , ccFlags :: [String]
    -- | Additional flags needed when compiling fltk.
    , fltkCc :: [String]
    -- | Additional flags needed when linking fltk.
    , fltkLd :: [String]
    -- | GHC-specific flags.  Unlike 'ccFlags', this *isn't* the complete list.
    , hcFlags :: [String]
    -- | Flags needed when linking haskell.  Doesn't include the -packages.
    , hLinkFlags :: [String]
    -- | Flags needed only by ghci.
    , ghciFlags :: [String]
    } deriving (Show)

instance Monoid.Monoid Flags where
    mempty = Flags [] [] [] [] [] [] [] [] []
    mappend (Flags a1 b1 c1 d1 e1 f1 g1 h1 i1)
            (Flags a2 b2 c2 d2 e2 f2 g2 h2 i2) =
        Flags (a1<>a2) (b1<>b2) (c1<>c2) (d1<>d2) (e1<>e2) (f1<>f2) (g1<>g2)
            (h1<>h2) (i1<>i2)

-- * binaries

-- This section has project specific hardcoded lists of files.

-- ** hs

data HsBinary = HsBinary {
    hsName :: FilePath
    , hsMain :: FilePath -- ^ main module
    , hsDeps :: [FilePath] -- ^ additional deps, relative to obj dir
    , hsGui :: Maybe Bool -- ^ Just if it's a GUI app and thus needs
    -- make_bundle on the mac, True if it has an icon at build/name.icns.
    } deriving (Show)

hsBinaries :: [HsBinary]
hsBinaries =
    [ gui "browser" "Instrument/Browser.hs" ["Instrument/browser_ui.cc.o"] True
    , plain "dump" "App/Dump.hs"
    , plain "logcat" "LogView/LogCat.hs"
    , gui "logview" "LogView/LogView.hs" ["LogView/logview_ui.cc.o"] True
    , plain "linkify" "Util/Linkify.hs"
    , plain "make_db" "Instrument/MakeDb.hs"
    , plain "pprint" "App/PPrint.hs"
    -- ExtractDoc wants the global keymap, which winds up importing cmds that
    -- directly call UI level functions.  Even though it doesn't call the
    -- cmds, they're packaged together with the keybindings, so I wind up
    -- having to link in all that stuff anyway.
    , HsBinary "extract_doc" "App/ExtractDoc.hs" ["fltk/fltk.a"] Nothing
    , plain "repl" "App/Repl.hs"
    , plain "send" "App/Send.hs"
    , gui "seq" "App/Main.hs" ["fltk/fltk.a"] True
    , plain "shakefile" "Shake/Shakefile.hs"
    , plain "test_midi" "Midi/TestMidi.hs"
    , plain "update" "App/Update.hs"
    ]
    where
    plain name path = HsBinary name path [] Nothing
    gui name path deps icon = HsBinary name path deps (Just icon)

runProfile :: FilePath
runProfile = modeToDir Profile </> "RunProfile"

runTests :: FilePath
runTests = modeToDir Test </> "RunTests"

-- | Hardcoded list of files that should be processed with CPP when chasing
-- deps.
cppFlags :: Config -> FilePath -> Maybe [String]
cppFlags config fn
    | fn `elem` cppFiles = Just $
        cInclude (configFlags config) ++ define (configFlags config)
    | otherwise = Nothing

-- | Hardcoded list of modules that use CPP to determine their imports.  This
-- means I need to CPP the file first before tracking the dependencies.
--
-- It would be more robust to always run CPP if the file includes
-- 'LANGUAGE .*CPP' but there aren't many modules with CPP in their import
-- lists so it should be faster to hardcode them.
cppFiles :: [FilePath]
cppFiles = ["App/Main.hs", "Cmd/Repl.hs", "Midi/TestMidi.hs", "Ui/Sync.hs"]

-- | Module that define 'main' and should get linked to their own binaries,
-- and the names of their eventual binaries.
nameToMain :: Map.Map FilePath FilePath
nameToMain = Map.fromList [(hsName b, hsMain b) | b <- hsBinaries]

-- | Haskell files that use the FFI likely have dependencies on C++ source.
-- I could figure this out automatically by looking for @foreign import ...@
-- and searching for a neighboring .cc file with those symbols, but it's
-- simpler to give the dependency explicitly.
hsToCc :: Map.Map FilePath [FilePath]
hsToCc = Map.fromList $
    [ ("Midi/CoreMidi.hs", ["Midi/core_midi.cc"])
    , ("Midi/JackMidi.hsc", ["Midi/jack.cc"])
    , ("LogView/LogViewC.hsc", ["LogView/interface.cc"])
    , ("Instrument/BrowserC.hsc", ["Instrument/interface.cc"])
    , ("Util/Fltk.hs", ["Util/fltk_interface.cc"])
    , ("Util/Git/LibGit2.hsc", ["Util/Git/libgit_wrappers.cc"])
    ] ++ [(hsc, ["Ui/c_interface.cc"])
        | hsc <- ["Ui/BlockC.hsc", "Ui/RulerC.hsc", "Ui/StyleC.hsc",
            "Ui/SymbolC.hsc", "Ui/TrackC.hsc", "Ui/UiMsgC.hsc"]]

-- | Another hack.  hsc2hs isn't really meant to work with C++, but it
-- basically does, and that way I don't have to strictly separate all the FFI
-- headers from the C++.
--
-- Unfortunately, g++ breaks the macros used by bindings-dsl:
hsc2hsNeedsC :: [FilePath]
hsc2hsNeedsC = ["Util/Git/LibGit2.hsc"]

-- | Rather than trying to figure out which binary needs which packages, I
-- just union all the packages.  TODO can I ask ghc to infer packages
-- automatically like --make?
packages :: [String]
packages = (if not useEkg then List.delete "ekg" else id) $
    map fst libraryDependencies

-- | When I pass the -package lines I do so without version numbers, so if
-- multiple versions are installed I may wind up with the wrong ones.
-- If for whatever reason I need to use some older version than the one
-- installed, this will probably pick the wrong version.
--
-- To fix that I'd have to do cabal's version search thing.  The cabal
-- code is in Distribution.PackageDescription.Configuration, but unfortunately
-- the interesting functions are all private.
libraryDependencies :: [(String, String)]
libraryDependencies = concat $
    -- really basic deps
    [ [("base", ">=4.6"), ("containers", ">=0.5")]
    , w "directory filepath process bytestring time unix array pretty"
    , w "ghc-prim"
    --  basic
    , w "transformers mtl deepseq data-ordlist cereal text stm network"
    , w "vector either utf8-string semigroups"
    , w "attoparsec" -- Derive: tracklang parsing
    -- Derive: score randomization
    , w "mersenne-random-pure64 digest random-shuffle"
    , w "dlist" -- Util.TimeVector
    , w "bindings-DSL" -- Util.Git.LibGit2
    , w "fclabels" -- Util.Lens
    , [("ghc", ">=7.6.1")] -- REPL
    , w "ghc-paths haskeline terminfo" -- REPL
    -- Instrument.Parse, could use attoparsec, but parsec errors are better
    , w "parsec"
    , w "haskell-src" -- Util.PPrint
    , [("regex-pcre", ""), ("Diff", ">=0.2")] -- Util.Test
    , w "QuickCheck" -- Derive.DeriveQuickCheck
    , [("shake", ">=0.10.8"), ("binary", ""), ("syb", "")] -- build system
    , w "ekg" -- removed if not useEkg, but is here so the cabal file has it
    , w "hashable zlib"
    , [("zmidi-core", ">=0.6")] -- for Cmd.Load.Midi
    ]
    where w = map (\p -> (p, "")) . words

-- ** cc

data CcBinary = CcBinary {
    ccName :: String
    , ccDeps :: [FilePath]
    } deriving (Show)

ccBinaries :: [CcBinary]
ccBinaries =
    [ CcBinary "test_block" ["fltk/test_block.cc.o", "fltk/fltk.a"]
    , CcBinary "test_browser" ["Instrument/test_browser.cc.o",
        "Instrument/browser_ui.cc.o", "fltk/f_util.cc.o"]
    , CcBinary "test_logview" ["LogView/test_logview.cc.o",
        "LogView/logview_ui.cc.o", "fltk/f_util.cc.o"]
    ]

fltkDeps :: Config -> [FilePath]
fltkDeps config = map (srcToObj config . ("fltk"</>))
    [ "Block.cc", "EventTrack.cc", "ExpandInput.cc", "MoveTile.cc"
    , "MsgCollector.cc", "P9Scrollbar.cc", "Ruler.cc", "SimpleScroll.cc"
    , "SkeletonDisplay.cc", "StyleTable.cc", "SymbolOutput.cc"
    , "SymbolTable.cc", "Track.cc", "TrackTile.cc", "WrappedInput.cc"
    , "alpha_draw.cc", "config.cc", "f_util.cc", "input_util.cc"
    , "types.cc", "util.cc"
    ]

-- * mode

data Mode = Debug | Opt | Test | Profile deriving (Eq, Enum, Show)

allModes :: [Mode]
allModes = [Debug .. Profile]

modeToDir :: Mode -> FilePath
modeToDir mode = (build </>) $ case mode of
    Debug -> "debug"
    Opt -> "opt"
    Test -> "test"
    Profile -> "profile"

targetToMode :: FilePath -> Maybe Mode
targetToMode target = snd <$> List.find ((`List.isPrefixOf` target) . fst)
    (zip (map modeToDir [Debug ..]) [Debug ..])

data MidiConfig = StubMidi | JackMidi | CoreMidi deriving (Show, Eq)

configure :: MidiConfig -> IO (Mode -> Config)
configure midi = do
    ghcLib <- run ghcBinary ["--print-libdir"]
    fltkCs <- words <$> run fltkConfig ["--cflags"]
    fltkLds <- words <$> run fltkConfig ["--ldflags"]
    fltkVersion <- takeWhile (/='\n') <$> run fltkConfig ["--version"]
    bindingsInclude <- run "ghc-pkg" ["field", "bindings-DSL", "include-dirs"]
    bindingsInclude <- case words bindingsInclude of
        [_, path] -> return path
        words -> error $ "unexpected output from ghc-pkg: " ++ show words
    return $ \mode -> Config (modeToDir mode) (build </> "hsc") (strip ghcLib)
        fltkVersion $ setCcFlags $
            setConfigFlags fltkCs fltkLds mode osFlags bindingsInclude
    where
    setConfigFlags fltkCs fltkLds mode flags bindingsInclude = flags
        { define = define osFlags
            ++ ["-DTESTING" | mode `elem` [Test, Profile]]
            ++ ["-DBUILD_DIR=\"" ++ modeToDir mode ++ "\""]
        , cInclude = ["-I.", "-I" ++ modeToDir mode, "-Ifltk",
            "-I" ++ bindingsInclude]
        , fltkCc = fltkCs
        , fltkLd = fltkLds
        , hcFlags = words "-threaded -W -fwarn-tabs -pgml g++"
            ++ ["-F", "-pgmF", hspp]
            ++ case mode of
                Debug -> []
                Opt -> ["-O"]
                Test -> ["-fhpc"]
                Profile -> ["-O", "-prof", "-auto-all", "-caf-all"]
        , hLinkFlags = libs ++ ["-rtsopts", "-threaded"]
            ++ ["-prof" | mode == Profile]
            ++ ["-with-rtsopts=-T" | useEkg]
        -- Hackery, make sure ghci gets link flags, otherwise it wants to
        -- load everything as bytecode and fails on missing symbols.  Actually,
        -- these only apply to loading the modules for the main app.  But
        -- that's where I care most about load time.
        , ghciFlags = libs ++ ["Util/Git/libgit_wrappers.cc"]
        }
    setCcFlags flags = flags
        { ccFlags =
            -- Always compile c++ with optimization because I don't have much
            -- of it and it compiles quickly.
            fltkCc flags ++ define flags ++ cInclude flags ++ ["-Wall", "-O2"]
                -- Turn on Effective C++ warnings, which includes uninitialized
                -- variables.  Unfortunately it's very noisy with lots of
                -- false positives.
                -- ++ ["-Weffc++"]
        }
    libs = ["-lgit2"]
    osFlags = case System.Info.os of
        -- In C and C++ programs the OS specific defines like __APPLE__ and
        -- __linux__ are already defined, but ghc doesn't define them.
        "darwin" -> mempty
            -- These apparently control which APIs are visible.  But they
            -- make it slightly more awkward for ghci since it needs the
            -- same flags to load .o files, and things seem to work without
            -- them, so I'll omit them for the time being.
            -- { define = ["-DMAC_OS_X_VERSION_MAX_ALLOWED=1060",
            --     "-DMAC_OS_X_VERSION_MIN_REQUIRED=1050"]
            { define = ["-D__APPLE__"]
            , midiLibs = if midi /= CoreMidi then [] else
                words $ "-framework CoreFoundation "
                    ++ "-framework CoreMIDI -framework CoreAudio"
            }
        "linux" -> mempty
            { midiLibs = if midi /= JackMidi then [] else ["-ljack"]
            , define = ["-D__linux__"]
            }
        _ -> mempty -- Use the stub driver.
    run cmd args = Process.readProcess cmd args ""

type InferConfig = FilePath -> Config

-- | Figure out the Config for a given target by looking at its directory.
inferConfig :: (Mode -> Config) -> InferConfig
inferConfig modeConfig fn =
    maybe (modeConfig Debug) modeConfig (targetToMode fn)

-- * rules

main :: IO ()
main = do
    IO.hSetBuffering IO.stdout IO.LineBuffering
    env <- Environment.getEnvironment
    modeConfig <- configure (midiFromEnv env)
    writeGhciFlags modeConfig
    Shake.shakeArgsWith defaultOptions [] $ \[] targets -> return $ Just $ do
        let infer = inferConfig modeConfig
        setupOracle env (modeConfig Debug)
        -- hspp is depended on by all .hs files.  To avoid recursion, I
        -- build hspp itself with --make.
        hspp *> \fn -> do
            -- But I need to mark hspp's deps so it will rebuild.
            need =<< HsDeps.transitiveImportsOf (const Nothing) "Util/Hspp.hs"
            Util.cmdline $ makeHs (oDir (modeConfig Opt)) fn "Util/Hspp.hs"
        matchObj "fltk/fltk.a" ?> \fn -> do
            let config = infer fn
            need (fltkDeps config)
            system "ar" $ ["-rs", fn] ++ fltkDeps config
        forM_ ccBinaries $ \binary -> matchBuildDir (ccName binary) ?> \fn -> do
            let config = infer fn
            let objs = map (oDir config </>) (ccDeps binary)
            need objs
            Util.cmdline $ linkCc config fn objs
            makeBundle fn False
        forM_ hsBinaries $ \binary -> matchBuildDir (hsName binary) ?> \fn -> do
            let config = infer fn
            hs <- maybe (errorIO $ "no main module for " ++ fn) return
                (Map.lookup (FilePath.takeFileName fn) nameToMain)
            buildHs config (map (oDir config </>) (hsDeps binary)) hs fn
            case hsGui binary of
                Just has_icon -> makeBundle fn has_icon
                _ -> return ()
        (build </> "*.icns") *> \fn -> do
            -- Build OS X .icns file from .iconset dir.
            let src = "doc/icon" </> replaceExt fn "iconset"
            need [src]
            system "iconutil" ["-c", "icns", "-o", fn, src]
        forM_ extractableDocs $ \fn ->
            fn *> extractDoc (modeConfig Debug)
        -- Always build, since it can't tell when 'libraryDependencies' has
        -- changed.
        Shake.phony "karya.cabal" $ makeCabal "karya.cabal"
        configHeaderRule
        testRules (modeConfig Test)
        profileRules (modeConfig Profile)
        markdownRule (buildDir (modeConfig Opt) </> "linkify")
        hsRule (modeConfig Debug) -- hsc2hs only uses mode-independent flags
        hsORule infer
        ccORule infer
        dispatch modeConfig targets

-- ** oracle

newtype Question a = Question () deriving
    ( Show, Generics.Typeable, Eq, Hashable.Hashable, Binary.Binary
    , DeepSeq.NFData
    )

data GhcQ deriving (Generics.Typeable)
data FltkQ deriving (Generics.Typeable)
data ReplQ deriving (Generics.Typeable)
data MidiQ deriving (Generics.Typeable)

setupOracle :: [(String, String)] -> Config -> Shake.Rules ()
setupOracle env config = do
    Shake.addOracle $ \(_ :: Question GhcQ) -> return (ghcLib config)
    Shake.addOracle $ \(_ :: Question FltkQ) -> return (fltkVersion config)
    Shake.addOracle $ \(_ :: Question ReplQ) ->
        return ("repl" `elem` map fst env)
    Shake.addOracle $ \(_ :: Question MidiQ) -> return (midiDriver :: String)
    return ()
    where
    midiDriver = case midiFromEnv env of
        StubMidi -> ""
        JackMidi -> "JACK_MIDI"
        CoreMidi -> "CORE_MIDI"

midiFromEnv :: [(String, String)] -> MidiConfig
midiFromEnv env = case lookup "midi" env of
      Just "stub" -> StubMidi
      Just "jack" -> JackMidi
      Just "core" -> CoreMidi
      Just unknown -> error $ "midi driver should be stub, jack, or core: "
        ++ show unknown
      Nothing -> case System.Info.os of
          "darwin" -> CoreMidi
          "linux" -> JackMidi
          _ -> StubMidi

-- ** misc rules

-- | Dynamically generated header.
hsconfigH :: FilePath
hsconfigH = "hsconfig.h"

-- | Write a header to configure the haskell compilation.
--
-- It's in a separate file so that the relevant haskell files can include it.
-- This way only those files will recompile when the config changes.
configHeaderRule :: Shake.Rules ()
configHeaderRule = matchBuildDir hsconfigH ?> \fn -> do
    useRepl <- Shake.askOracle (Question () :: Question ReplQ)
    useRepl <- return $ useRepl && targetToMode fn /= Just Test
    midiDriver <- Shake.askOracle (Question () :: Question MidiQ)
    Shake.writeFileChanged fn $ unlines
        [ "/* Created automatically by the shakefile. */"
        , "#ifndef __HSCONFIG_H"
        , "#define __HSCONFIG_H"
        , define useRepl "INTERPRETER_GHC"
        , define (not (null midiDriver)) midiDriver
        , define useEkg "USE_EKG"
        , "#endif"
        ]
    where
    define b name = if b then "#define " ++ name else ""

-- | Match a file in @build/<mode>/obj/@ or @build/<mode>/@.
matchObj :: Shake.FilePattern -> FilePath -> Bool
matchObj pattern fn =
    matchPrefix (map ((</> "obj") . modeToDir) allModes) pattern fn
    || matchPrefix (map modeToDir allModes) pattern fn

-- | Match a file in @build/<mode>/@.
matchBuildDir :: Shake.FilePattern -> FilePath -> Bool
matchBuildDir = matchPrefix (map modeToDir allModes)

matchPrefix :: [Shake.FilePattern] -> Shake.FilePattern -> FilePath -> Bool
matchPrefix prefixes pattern fn =
    case msum $ map (flip dropPrefix fn) prefixes of
        Nothing -> False
        Just rest -> pattern ?== (dropWhile (=='/') rest)

dispatch :: (Mode -> Config) -> [String] -> Shake.Rules ()
dispatch modeConfig targets = do
    handled <- mapM hardcoded targets
    Shake.want [target | (False, target) <- zip handled targets]
    where
    hardcoded target = case target of
        -- I should probably run this in staunch mode, -k.
        "checkin" -> do
            let debug = (modeToDir Debug </>)
            Shake.want $
                [ debug "browser", debug "logview", debug "make_db"
                , debug "seq", debug "update", debug "dump", debug "repl"
                , debug "test_midi", runProfile
                , "karya.cabal"
                ] ++ extractableDocs
            dispatch modeConfig ["tests"]
            -- The gui tests tend to wedge.
            -- dispatch config "complete-tests"
            return True
        "binaries" -> do
            Shake.want $ map (modeToDir Opt </>)
                ["browser", "logview", "make_db", "seq", "repl", "test_midi"]
            return True
        "clean" -> action $ do
            -- The shake database will remain because shake creates it after the
            -- shakefile runs, but that's probably ok.
            system "rm" ["-rf", build]
            system "mkdir" [build]
        "doc" -> action $ makeAllDocumentation (modeConfig Test)
        "haddock" -> action $ makeHaddock (modeConfig Test)
        "hlint" -> action $ hlint (modeConfig Debug)
        "md" -> action $ need . map docToHtml =<< getMarkdown
        "profile" -> action $ do
            need [runProfile]
            let with_scc = "-auto-all"
                    `elem` hcFlags (configFlags (modeConfig Profile))
            system "tools/summarize_profile.py"
                [if with_scc then "scc" else "no-scc"]
        "show-debug" -> action $
            Trans.liftIO $ PPrint.pprint (modeConfig Debug)
        "show-opt" -> action $
            Trans.liftIO $ PPrint.pprint (modeConfig Opt)
        "tests" -> action $ do
            need [runTestsTarget Nothing]
            system "test/run_tests" [runTestsTarget Nothing]
        "tests-complete" -> action $ do
            need [runTestsTarget Nothing]
            system "test/run_tests" [runTestsTarget Nothing, "normal-", "gui-"]
        (dropPrefix "tests-" -> Just tests) -> action $ do
            need [runTestsTarget (Just tests)]
            system "test/run_tests" [runTestsTarget (Just tests)]
        _ -> return False
    action act = Shake.action act >> return True
    runTestsTarget tests = runTests ++ maybe "" ('-':) tests

hlint :: Config -> Shake.Action ()
hlint config = do
    (hs, hscs) <- getAllHaddock
    need $ map (hscToHs (hscDir config)) hscs
    Util.staunchSystem "hlint" $ mkIgnore hlintIgnore ++ hs
    Util.staunchSystem "hlint" $ mkIgnore
        -- hsc2hs triggers these, not my fault.
        (hlintIgnore ++ ["Redundant bracket", "Avoid lambda"])
        ++ map (hscToHs (hscDir config)) hscs
    where
    mkIgnore = map ("--ignore="++)

hlintIgnore :: [String]
hlintIgnore =
    [ "Use camelCase", "Use &&&", "Use uncurry", "Use section"
    , "Use infix", "Use maybeToList", "Use join", "Use String"
    , "Redundant lambda", "Avoid lambda" -- I do it on purpose for clarity.
    , "Use import/export shortcut" -- Weird, don't like it.
    , "Use elem" -- I don't use elem for 2 element lists.
    , "Use isNothing" -- ==Nothing is nice too.
    ]

-- * doc

-- | Make all documentation.
makeAllDocumentation :: Config -> Shake.Action ()
makeAllDocumentation config = do
    (hs, hscs) <- getAllHaddock
    docs <- getMarkdown
    need $ extractableDocs
        ++ map (hscToHs (hscDir config)) hscs ++ map docToHtml docs
    makeHaddock config
    -- TODO do these individually so they can be parallelized and won't run
    -- each time
    system "tools/colorize" $ (build </> "hscolour") : hs ++ hscs

-- | Docs produced by extract_doc.
extractableDocs :: [FilePath]
extractableDocs = map (docDir </>) ["keymap.html", "calls.html", "scales.html"]

extractDoc :: Config -> FilePath -> Shake.Action ()
extractDoc config fn = do
    let bin = buildDir config </> "extract_doc"
    need [bin]
    let name = FilePath.takeFileName (FilePath.dropExtension fn)
    Util.shell $ unwords [bin, name, ">", fn]

getMarkdown :: Shake.Action [FilePath]
getMarkdown = map ("doc"</>) <$> Shake.getDirectoryFiles "doc" ["*.md"]

makeHaddock :: Config -> Shake.Action ()
makeHaddock config = do
    (hs, hscs) <- getAllHaddock
    need $ (buildDir config </> hsconfigH)
        : map (hscToHs (hscDir config)) hscs
    let flags = configFlags config
    interfaces <- Trans.liftIO getHaddockInterfaces
    system "haddock" $
        [ "--html", "-B", ghcLib config
        , "--source-base=../hscolour/"
        , "--source-module=../hscolour/%{MODULE/.//}.html"
        , "--source-entity=../hscolour/%{MODULE/.//}.html#%{NAME}"
        , "--prologue=doc/prologue"
        -- Source references qualified names as written in the doc.
        , "-q", "aliased"
        , "-o", build </> "haddock"
        ] ++ map ("-i"++) interfaces
        ++ ["--optghc=" ++ flag | flag <- define flags ++ cInclude flags
            ++ ghcLanguageFlags]
        ++ hs ++ map (hscToHs (hscDir config)) hscs

-- | Get paths to haddock interface files for all the packages.
getHaddockInterfaces :: IO [String]
getHaddockInterfaces = do
    -- ghc-pkg annoyingly provides no way to get a field from a list of
    -- packages.
    interfaces <- forM packages $ \package -> Process.readProcess "ghc-pkg"
        ["field", package, "haddock-interfaces"] ""
    return $ map extract interfaces
    where
    -- If multiple versions are installed, this will return multiple lines.
    -- I should probably make sure to get the latest non-hidden one as the
    -- -package flag does by default, but ghc-pkg is too primitive so I'll
    -- just pick the first one for now.
    extract = drop 1 . dropWhile (/=' ') . takeWhile (/='\n')

getAllHaddock :: Shake.Action ([FilePath], [FilePath])
getAllHaddock = do
    hs <- filter wantsHaddock <$> Util.findHs "*.hs" "."
    hscs <- filter wantsHaddock <$> Util.findHs "*.hsc" "."
    return (hs, hscs)

-- | Should this module have haddock documentation generated?
wantsHaddock :: FilePath -> Bool
wantsHaddock hs = not $ or
    [ "_test.hs" `List.isSuffixOf` hs
    , "_profile.hs" `List.isSuffixOf` hs
    -- This will crash haddock on OS X since jack.h is likely not present.
    -- TODO sorta hacky
    , hs == "Midi/JackMidi.hsc"
    ]

-- * cabal

makeCabal :: FilePath -> Shake.Action ()
makeCabal fn = do
    template <- Shake.readFile' "doc/karya.cabal.template"
    Shake.writeFile' fn $ template ++ buildDepends ++ "\n"
    where
    indent = replicate 8 ' '
    buildDepends = (indent++) $ List.intercalate (",\n" ++ indent) $
        map mkline libraryDependencies
    mkline (package, constraint) =
        package ++ if null constraint then "" else " " ++ constraint

-- * hs

makeHs :: FilePath -> FilePath -> FilePath -> Util.Cmdline
makeHs dir out main = ("GHC-MAKE", out, cmdline)
    where
    cmdline = [ghcBinary, "--make", "-outputdir", dir, "-O2", "-o", out,
        "-main-is", pathToModule main, main]

-- | Build a haskell binary.
buildHs :: Config -> [FilePath] -> FilePath -> FilePath -> Shake.Action ()
buildHs config deps hs fn = do
    need [buildDir config </> hsconfigH]
    srcs <- HsDeps.transitiveImportsOf (cppFlags config) hs
    let ccs = List.nub $
            concat [Map.findWithDefault [] src hsToCc | src <- srcs]
        objs = List.nub (map (srcToObj config) (ccs ++ srcs)) ++ deps
    logDeps config "build" fn objs
    Util.cmdline $ linkHs config fn packages objs

makeBundle :: FilePath -> Bool -> Shake.Action ()
makeBundle binary has_icon
    | System.Info.os == "darwin" = do
        need icon
        system "tools/make_bundle" (binary : icon)
    | otherwise = return ()
    where icon = [build </> replaceExt binary "icns" | has_icon]

-- * tests and profiles

-- | Generate RunTests.hs and compile it.
testRules :: Config -> Shake.Rules ()
testRules config = do
    runTests ++ "*.hs" *> generateTestHs "_test"
    hasPrefix runTests ?> \fn -> do
        -- The UI tests use fltk.a.  It would be nicer to have it
        -- automatically added when any .o that uses it is linked in.
        buildHs config [oDir config </> "fltk/fltk.a"] (fn ++ ".hs") fn
        -- This sticks around and breaks hpc.
        system "rm" ["-f", replaceExt fn "tix"]
        -- This gets reset on each new test run.
        system "rm" ["-f", "test.output"]

profileRules :: Config -> Shake.Rules ()
profileRules config = do
    runProfile ++ "*.hs" *> generateTestHs "_profile"
    hasPrefix runProfile ?> \fn ->
        buildHs config [oDir config </> "fltk/fltk.a"] (fn ++ ".hs") fn

-- | Match any filename that starts with the given prefix but doesn't have
-- an extension, i.e. binaries.
hasPrefix :: FilePath -> FilePath -> Bool
hasPrefix prefix fn =
    prefix `List.isPrefixOf` fn && null (FilePath.takeExtension fn)

generateTestHs :: FilePath -> FilePath -> Shake.Action ()
generateTestHs hsSuffix fn = do
    let contains = drop 1 $ dropWhile (/='-') $ FilePath.dropExtension fn
        pattern = (if null contains then "" else '*' : contains)
            ++ "*" ++ hsSuffix ++ ".hs"
    tests <- Util.findHs pattern "."
    when (null tests) $
        errorIO $ "no tests match pattern: " ++ show pattern
    need $ "test/generate_run_tests.py" : tests
    system "test/generate_run_tests.py" (fn : tests)

-- * markdown

markdownRule :: FilePath -> Shake.Rules ()
markdownRule linkifyBin = docDir </> "*.md.html" *> \html -> do
    let doc = htmlToDoc html
    need [linkifyBin, doc]
    system "tools/convert_doc" [doc, html] -- wrapper around pandoc

-- | build/doc/xyz.md.html -> doc/xyz.md
htmlToDoc :: FilePath -> FilePath
htmlToDoc = ("doc" </>) . FilePath.takeFileName . FilePath.dropExtension

-- | doc/xyz.md -> build/doc/xyz.md.html
docToHtml :: FilePath -> FilePath
docToHtml = (docDir </>) . FilePath.takeFileName . (++".html")

-- * hs

hsORule :: InferConfig -> Shake.Rules ()
hsORule infer = matchHsObj ?>> \fns -> do
    let Just obj = List.find (".hs.o" `List.isSuffixOf`) fns
    Shake.askOracleWith (Question () :: Question GhcQ) ("" :: String)
    let config = infer obj
    isHsc <- Trans.liftIO $
        Directory.doesFileExist (objToSrc config obj ++ "c")
    let hs = if isHsc then objToHscHs config obj else objToSrc config obj
    need [hspp]
    imports <- HsDeps.importsOf (cppFlags config hs) hs
    includes <- if Maybe.isJust (cppFlags config hs)
        then includesOf "hsORule" config hs else return []
    need includes
    let his = map (objToHi . srcToObj config) imports
    -- I depend on the .hi files instead of the .hs.o files.  GHC avoids
    -- updaing the timestamp on the .hi file if its .o didn't need to be
    -- recompiled, so hopefully this will avoid some work.
    logDeps config "hs" obj (hs:his)
    Util.cmdline $ compileHs config hs

-- | Generate both .hs.o and .hi from a .hs file.
matchHsObj :: FilePath -> Maybe [FilePath]
matchHsObj fn
    | any (`List.isSuffixOf` fn) [".hs.o", ".hi"]
            && "build/" `List.isPrefixOf` fn =
        if isMain then Just [suffixless ++ ".hs.o"]
            else Just [suffixless ++ ".hs.o", suffixless ++ ".hi"]
    | otherwise = Nothing
    where
    suffixless = dropExtension fn
    hs = suffixless ++ ".hs"
    -- Hack: main modules are sometimes called Main, so their .hi file doesn't
    -- have the same name as the module.  But no one should be importing them,
    -- so I don't need to track the .hi.
    isMain = Map.member hs nameToMain
        || hs == runProfile ++ ".hs" || hs == runTests ++ ".hs"

compileHs :: Config -> FilePath -> Util.Cmdline
compileHs config hs = ("GHC", hs,
    [ghcBinary, "-c"] ++ ghcFlags config ++ hcFlags (configFlags config)
        ++ mainIs ++ packageFlags ++ [hs, "-o", srcToObj config hs])
    where
    packageFlags = ["-hide-all-packages"] ++ map ("-package="++) packages
    mainIs = if hs `elem` Map.elems nameToMain
        then ["-main-is", pathToModule hs]
        else []

linkHs :: Config -> FilePath -> [String] -> [FilePath] -> Util.Cmdline
linkHs config output packages objs = ("LD-HS", output,
    ghcBinary : fltkLd flags ++ midiLibs flags ++ hLinkFlags flags
        ++ ["-lstdc++"]
        ++ ["-hide-all-packages"] ++ map ("-package="++) packages
        ++ objs ++ ["-o", output])
    where flags = configFlags config

-- | ghci has to be called with the same flags that the .o files were compiled
-- with or it won't load them.
writeGhciFlags :: (Mode -> Config) -> IO ()
writeGhciFlags modeConfig =
    forM_ (map modeConfig allModes) $ \config -> do
        Directory.createDirectoryIfMissing True (buildDir config)
        writeFile (buildDir config </> "ghci-flags") $
            unwords (getFlags config) ++ "\n"
    where
    -- Make sure -osuf .hs.o is in the flags, otherwise ghci won't know
    -- how to find the .o files.  But it's redundant for the ghc compile,
    -- which uses -o.
    -- I have to add -I. manually too since it's in hcFlags along with
    -- non-ghci stuff, not ghcFlags.  I'd have to add a new config field for
    -- non-file-specific ghc flags, or put -I in 'define', where it doesn't
    -- belong.
    getFlags config = ["-osuf", ".hs.o"]
        ++ ghcFlags config
        ++ map (resolveSrc config) (ghciFlags (configFlags config))
    resolveSrc config arg
        | FilePath.takeExtension arg == ".cc" = srcToObj config arg
        | otherwise = arg

-- | Get the file-independent flags for a haskell compile.
ghcFlags :: Config -> [String]
ghcFlags config =
    [ "-outputdir", oDir config
    , "-i" ++ oDir config ++ ":" ++ hscDir config
    ] ++ ghcLanguageFlags ++ define (configFlags config)
    ++ cInclude (configFlags config)

ghcLanguageFlags :: [String]
ghcLanguageFlags = map ("-X"++) ["OverloadedStrings"]

-- * cc

ccORule :: InferConfig -> Shake.Rules ()
ccORule infer = matchObj "//*.cc.o" ?> \obj -> do
    Shake.askOracleWith (Question () :: Question FltkQ) ("" :: String)
    let config = infer obj
    let cc = objToSrc config obj
    includes <- includesOf "ccORule" config cc
    logDeps config "cc" obj (cc:includes)
    Util.cmdline $ compileCc config cc obj

compileCc :: Config -> FilePath -> FilePath -> Util.Cmdline
compileCc config cc obj = ("C++", obj,
    ["g++", "-c"] ++ ccFlags (configFlags config) ++ ["-o", obj, cc])

linkCc :: Config -> FilePath -> [FilePath] -> Util.Cmdline
linkCc config binary objs = ("LD-CC", binary,
    "g++" : objs ++ fltkLd (configFlags config) ++ ["-o", binary])

-- * hsc

hsRule :: Config -> Shake.Rules ()
hsRule config = hscDir config ++ "//*.hs" *> \hs -> do
    let hsc = hsToHsc (hscDir config) hs
    includes <- includesOf "hsRule" config hsc
    logDeps config "hsc" hs (hsc : includes)
    Util.cmdline $ hsc2hs config (hsc `notElem` hsc2hsNeedsC) hs hsc

hsc2hs :: Config -> Bool -> FilePath -> FilePath -> Util.Cmdline
hsc2hs config useCpp hs hsc = ("hsc2hs", hs,
    ["hsc2hs", "-I" ++ ghcLib config </> "include"]
    ++ (if useCpp
        -- Otherwise g++ complains about the offsetof macro hsc2hs uses.
        then words "-c g++ --cflag -Wno-invalid-offsetof"
        else [])
    ++ cInclude flags ++ fltkCc flags ++ define flags
    ++ [hsc, "-o", hs])
    where flags = configFlags config

-- * util

-- | A/B.hs -> build/debug/obj/A/B.hs.o
-- A/B.cc -> build/debug/obj/A/B.cc.o
-- A/B.hsc -> build/debug/obj/A/B.hs.o
-- build/A/B.hs -> build/A/B.hs.o
-- build/hsc/Ui/Key.hs -> build/debug/obj/Ui/Key.hs.o
--
-- Generated .hs files are already in build/ so they shouldn't have build/etc.
-- prepended.  Unless they were .hsc generated files.
srcToObj :: Config -> FilePath -> FilePath
srcToObj config fn = addDir $ case FilePath.takeExtension fn of
    ".hs" -> FilePath.addExtension fn "o"
    ".hsc" -> FilePath.replaceExtension fn "hs.o"
    ".cc" -> FilePath.addExtension fn "o"
    _ -> error $ "unknown haskell extension: " ++ show fn
    where
    addDir
        | hscDir config `List.isPrefixOf` fn =
            (oDir config </>) . dropDir (hscDir config)
        | build `List.isPrefixOf` fn = id
        | otherwise = (oDir config </>)

-- | build/debug/A/B.hs.o -> A/B.hs
objToSrc :: Config -> FilePath -> FilePath
objToSrc config = FilePath.dropExtension . dropDir (oDir config)

-- | build/debug/A/B.o -> build/hsc/A/B.hs
objToHscHs :: Config -> FilePath -> FilePath
objToHscHs config = (hscDir config </>) . objToSrc config

-- | build/hsc/A/B.hs -> A/B.hsc
hsToHsc :: FilePath -> FilePath -> FilePath
hsToHsc hscDir fn = dropDir hscDir $ FilePath.replaceExtension fn "hsc"

-- | A/B.hsc -> build/hsc/A/B.hs
hscToHs :: FilePath -> FilePath -> FilePath
hscToHs hscDir fn = (hscDir </>) $ FilePath.replaceExtension fn "hs"

objToHi :: FilePath -> FilePath
objToHi = (++".hi") . dropExtension

hiToObj :: FilePath -> FilePath
hiToObj = flip FilePath.replaceExtension "hs.o"

dropExtension :: FilePath -> FilePath
dropExtension fn
    | ".hs.o" `List.isSuffixOf` fn = take (length fn - 5) fn
    | otherwise = FilePath.dropExtension fn

dropDir :: FilePath -> FilePath -> FilePath
dropDir odir fn
    | dir `List.isPrefixOf` fn = drop (length dir) fn
    | otherwise = fn
    where dir = odir ++ "/"

strip :: String -> String
strip = reverse . dropWhile Char.isSpace . reverse . dropWhile Char.isSpace

errorIO :: (Trans.MonadIO m) => String -> m a
errorIO = Trans.liftIO . Exception.throwIO . Exception.ErrorCall

pathToModule :: FilePath -> String
pathToModule = map (\c -> if c == '/' then '.' else c) . FilePath.dropExtension

logDeps :: Config -> String -> FilePath -> [FilePath] -> Shake.Action ()
logDeps config stage fn deps = do
    need deps
    Shake.putLoud $ "***" ++ stage ++ ": " ++ fn ++ " <- "
        ++ unwords (map (dropDir (oDir config)) deps)

includesOf :: String -> Config -> FilePath -> Shake.Action [FilePath]
includesOf caller config fn = do
    let dirs = [dir | '-':'I':dir <- cInclude (configFlags config)]
    (includes, not_found) <- CcDeps.transitiveIncludesOf dirs fn
    unless (null not_found) $
        Trans.liftIO $ putStrLn $ caller
            ++ ": WARNING: c includes not found: " ++ show not_found
            ++ " (looked in " ++ show dirs ++ ")"
    return includes

dropPrefix :: String -> String -> Maybe String
dropPrefix pref str
    | pref `List.isPrefixOf` str = Just (drop (length pref) str)
    | otherwise = Nothing

replaceExt :: FilePath -> String -> FilePath
replaceExt fn = FilePath.replaceExtension (FilePath.takeFileName fn)

mlast :: [a] -> Maybe a
mlast [] = Nothing
mlast xs = Just (last xs)
