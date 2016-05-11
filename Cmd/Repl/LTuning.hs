-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{- | Functions to deal with tuning instruments.

    E.g.:

    > LTuning.realtime "pno" =<< LTuning.selection True
    > LTuning.write_ksp "charu.ksp" =<<LTuning.scale True "raga" "key=charukesi"

    Don't forget to set the score to the same scale or things will sound
    confusing.  Also, reaper won't receive sysex on a track unless you set it
    to receive all channels.
-}
module Cmd.Repl.LTuning where
import qualified Data.Maybe as Maybe
import qualified Data.Text as Text
import qualified Data.Text.IO as Text.IO
import qualified Data.Vector.Unboxed as Unboxed

import qualified Util.Num as Num
import qualified Util.Seq as Seq
import qualified Util.TextUtil as TextUtil

import qualified Midi.Midi as Midi
import qualified Cmd.Cmd as Cmd
import qualified Cmd.InputNote as InputNote
import qualified Cmd.Perf as Perf
import qualified Cmd.PlayUtil as PlayUtil
import qualified Cmd.Repl.LInst as LInst
import qualified Cmd.Repl.Util as Util
import qualified Cmd.Selection as Selection

import qualified Derive.Call as Call
import qualified Derive.Call.Prelude.Equal as Equal
import qualified Derive.Derive as Derive
import qualified Derive.Scale as Scale
import qualified Derive.Scale.BaliScales as BaliScales
import qualified Derive.Scale.Legong as Legong
import qualified Derive.Scale.Wayang as Wayang

import qualified Perform.Midi.Patch as Patch
import qualified Perform.Pitch as Pitch
import qualified Local.Instrument.Kontakt.Util as Kontakt.Util
import Global
import Types


-- * Patch.Scale

-- | Format a Patch.Scale as a table.
table :: Patch.Scale -> Text
table (Patch.Scale _ nns) =
    Text.unlines $ TextUtil.formatColumns 1 $
        ["", "c", "", "d", "", "e", "f", "", "g", "", "a", "", "b"]
        : [oct : map (Num.showFloat 2) nns | (oct, nns) <- zip octaves groups]
    where
    octaves = map (("c"<>) . showt) [-1..]
    groups = Seq.chunked 12 $ Unboxed.toList nns

-- | Get a patch scale for the scale at the selection.
selection :: Cmd.M m => Bool
    -- ^ False to check for warnings and errors, True to ignore them.
    -> m Patch.Scale
selection ignore_errors = do
    (block_id, _, track_id, _) <- Selection.get_insert
    (scale, errs) <- scale_at block_id track_id
    unless (ignore_errors || null errs) $
        Cmd.throw $ Text.unlines errs
    return scale

scale_at :: Cmd.M m => BlockId -> TrackId -> m (Patch.Scale, [Text])
scale_at block_id track_id = do
    scale <- Perf.get_derive_at block_id track_id Call.get_scale
    (key_nns, errs) <- fmap unzip $ forM all_inputs $ \(key, input) -> do
        let at_time = 0
        (val, logs) <- Perf.derive_at block_id track_id $
            Scale.scale_input_to_nn scale at_time input
        let prefix = (("key " <> pretty key <> ": ") <>)
        return $ second (map prefix . (++ map pretty logs)) $ case val of
            Left err -> (Nothing, [err])
            Right (Left err) -> (Nothing, [pretty err])
            Right (Right nn) -> (Just (key, nn), [])
    let name = pretty (Scale.scale_id scale)
    return (Patch.make_scale name (Maybe.catMaybes key_nns), concat errs)

-- | Create a Patch.Scale for the named scale.
named :: Cmd.M m => Bool
    -- ^ False to check for warnings and errors, True to ignore them.
    -> Text -> Text -> m Patch.Scale
named ignore_errors name transform = do
    scale <- get_scale name
    (scale, errs) <- make_patch_scale scale transform
    unless (ignore_errors || null errs) $
        Cmd.throw $ Text.unlines errs
    return scale

get_scale :: Cmd.M m => Text -> m Scale.Scale
get_scale name =
    Cmd.require ("scale not found: " <> name)
        =<< Perf.lookup_scale_env mempty (Pitch.ScaleId name)

make_patch_scale :: Cmd.M m => Scale.Scale -> Text -> m (Patch.Scale, [Text])
make_patch_scale scale transform = do
    (key_nns, errs) <- fmap unzip $ forM all_inputs $ \(key, input) -> do
        let at_time = 0
        (val, logs) <- derive $ Equal.transform_expr transform $
            Scale.scale_input_to_nn scale at_time input
        let prefix = (("key " <> pretty key <> ": ") <>)
        return $ second (map prefix . (++ logs)) $ case val of
            Nothing -> (Nothing, [])
            Just (Left err) -> (Nothing, [pretty err])
            Just (Right nn) -> (Just (key, nn), [])
    let name = pretty (Scale.scale_id scale)
    return (Patch.make_scale name (Maybe.catMaybes key_nns), concat errs)

derive :: Cmd.M m => Derive.Deriver a -> m (Maybe a, [Text])
derive deriver = do
    (val, _, logs) <- PlayUtil.run mempty mempty deriver
    return $ case val of
        Left err -> (Nothing, pretty err : map pretty logs)
        Right val -> (Just val, map pretty logs)

all_inputs :: [(Midi.Key, Pitch.Input)]
all_inputs = [(key, InputNote.nn_to_input (key_to_nn key)) | key <- [0..127]]
    where key_to_nn = Midi.from_key


-- * retune

-- | Set the instrument's Scale to the given scale and send a MIDI tuning
-- message to retune the synth.  Very few synths support this, I only know of
-- pianoteq.
realtime :: Cmd.M m => Util.Instrument -> Patch.Scale -> m ()
realtime inst scale = do
    LInst.set_scale inst scale
    (_, _, config) <- LInst.get_midi_config (Util.instrument inst)
    let devs = map (fst . fst) (Patch.config_addrs config)
    let msg = Midi.realtime_tuning $ map (second Pitch.nn_to_double) $
            Patch.scale_keys scale
    mapM_ (flip Cmd.midi msg) (Seq.unique devs)

-- | Write KSP to retune a 12TET patch.  Don't forget to do 'LInst.set_scale'
-- to configure the instrument.
write_ksp :: FilePath -> Patch.Scale -> Cmd.CmdT IO ()
write_ksp filename scale = do
    ksp <- Cmd.require_right id $ Kontakt.Util.tuning_ksp scale
    liftIO $ Text.IO.writeFile filename ksp
    return ()

write_bali_scales_ksp :: Cmd.CmdT IO ()
write_bali_scales_ksp = mapM_ (uncurry write_ksp)
    [ ("wayang-umbang.ksp",
        Wayang.instrument_scale True BaliScales.Umbang)
    , ("wayang-isep.ksp",
        Wayang.instrument_scale True BaliScales.Isep)
    , ("legong-umbang.ksp",
        Legong.complete_instrument_scale BaliScales.Umbang)
    , ("legong-isep.ksp",
        Legong.complete_instrument_scale BaliScales.Isep)
    ]
