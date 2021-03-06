-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Setup StaticConfig.
module User.Elaforge.Config (load_static_config) where
import qualified Data.Map as Map
import qualified Network.BSD
import qualified System.FilePath as FilePath

import qualified Util.Log as Log
import qualified Util.Seq as Seq
import qualified Midi.Key as Key
import qualified Ui.Id as Id
import qualified Ui.Ui as Ui
import qualified Cmd.Cmd as Cmd
import qualified Cmd.Controller as Controller
import qualified Cmd.Load.Med as Load.Med
import qualified Cmd.Load.Mod as Load.Mod
import qualified Cmd.Msg as Msg

import qualified Derive.C.All as C.All
import qualified User.Elaforge.Config.Tammananny as Tammananny
import qualified User.Elaforge.Config.Hobbes as Hobbes
import qualified App.Config as Config
import qualified App.LoadInstruments as LoadInstruments
import qualified App.ParseArgs as ParseArgs
import qualified App.StaticConfig as StaticConfig

import Global


load_static_config :: IO StaticConfig.StaticConfig
load_static_config = do
    app_dir <- Config.get_app_dir
    instrument_db <- LoadInstruments.load app_dir
    midi <- get_midi_config instrument_db
    return $ StaticConfig.StaticConfig
        { instrument_db = instrument_db
        , global_cmds = global_cmds
        , builtins = C.All.builtins
        , setup_cmd = parse_args
        , midi = midi
        , highlight_colors = Config.highlight_colors
        }

parse_args :: [String] -> Either Text (Cmd.CmdT IO Cmd.Status)
parse_args = \case
    ["med", fn] -> Right $ load_med fn
    args -> ParseArgs.parse_args args

oxygen8_v2 :: Controller.TransportConfig
oxygen8_v2 = Controller.TransportConfig
    { config_repeat = note_on Key.cs_1
    , config_backward = note_on Key.ds_1
    , config_forward = note_on Key.fs_1
    , config_stop = note_on Key.gs_1
    , config_play = note_on Key.as_1
    , config_record = note_on Key.cs0
    }
    where note_on = Controller.note_on

global_cmds :: [Msg.Msg -> Cmd.CmdT IO Cmd.Status]
global_cmds =
    [ Controller.transport oxygen8_v2
    ]

get_midi_config :: Cmd.InstrumentDb -> IO StaticConfig.Midi
get_midi_config db = do
    full_host <- Network.BSD.getHostName
    case takeWhile (/='.') full_host of
        "tammananny" -> return $ Tammananny.midi_config db
        "hobbes" -> return $ Hobbes.midi_config db
        host -> do
          Log.warn $ "no midi configuration for host: " <> showt host
          return StaticConfig.empty_midi

-- * med

load_med :: FilePath -> Cmd.CmdT IO Cmd.Status
load_med fn = do
    let inst_map = Map.findWithDefault mempty (FilePath.takeFileName fn)
            inst_maps
    mod <- liftIO $ Load.Med.load inst_map fn
    state <- Cmd.require_right pretty $ Load.Mod.convert (fn_to_ns fn) mod
    Ui.put state
    return Cmd.Done

fn_to_ns :: FilePath -> Id.Namespace
fn_to_ns = Id.namespace . txt . head . Seq.split "." . FilePath.takeFileName

inst_maps :: Map FilePath (Map Text Text)
inst_maps = Map.fromList
    [ ("underwater", Map.fromList
        [ ("Takerimba", "marim")
        , ("SoftShake", "shake")
        , ("Thumb Bass", "bass")
        , ("HeavyBassDrum", "bd")
        , ("SD1", "sd")
        , ("FireHiSyn", "lead")
        , ("VCO Bass", "synb")
        , ("Chin-PanFluteLooped", "pan")
        , ("WoodPf (4/29)", "wood")
        , ("RainyHiMajor", "maj")
        , ("RainyHiMinor", "min")
        , ("technoRush-loud", "rush1")
        , ("technoRush2", "rush2")
        , ("D50-PizzaGogo", "pizz")
        , ("filter.maj", "fmaj")
        ])
    , ("piano", Map.fromList
        [ ("UpPiano (4/1)", "pno")
        , ("UprtBass (6/20)", "bass")
        , ("Glockn2 (6/36)", "glock")
        , ("BigPipe (7/13)", "pipe")
        , ("String2 (5/17)", "string")
        , ("TubeBe1 (6/37)", "bell")
        ])
    , ("Elektrodes", Map.fromList
        [ ("Elektrodes", "elec")
        , ("Jazz Man", "bass")
        , ("440thick-bk", "bd")
        , ("AquaSnare", "sn")
        , ("AlesisHihatC", "hh-c")
        , ("AlesisHihatO", "hh-o")
        , ("AlesisHihatM", "hh-m")
        , ("CheckHiSyn-loud", "syn")
        , ("ClassPiano", "pno")
        , ("BstTom", "tom")
        , ("SundanceJazzHit", "hit")
        ])
    ]
