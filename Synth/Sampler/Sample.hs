-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE DeriveGeneric #-}
-- | The 'Sample' type and support.
module Synth.Sampler.Sample where
import System.FilePath ((</>))

import qualified Util.Audio.Audio as Audio
import qualified Util.Audio.File as Audio.File
import qualified Util.Audio.Resample as Resample
import qualified Util.Num as Num
import qualified Util.Test.ApproxEq as ApproxEq

import qualified Perform.RealTime as RealTime
import qualified Synth.Lib.AUtil as AUtil
import Synth.Lib.Global
import qualified Synth.Sampler.Config as Config
import qualified Synth.Shared.Signal as Signal

import Global


-- | Path to a sample, relative to the instrument db root.
type SamplePath = FilePath

-- | Low level representation of a note.  This corresponds to a single sample
-- played.
data Sample = Sample {
    start :: !RealTime
    -- | Relative to 'Config.instrumentDbDir'.
    , filename :: !SamplePath
    -- | Sample start offset.
    , offset :: !RealTime
    -- | The sample ends when it runs out of samples, or when envelope ends
    -- on 0.
    , envelope :: !Signal.Signal
    -- | Sample rate conversion ratio.  This controls the pitch.
    , ratio :: !Signal.Signal
    } deriving (Show)

render :: Resample.Config -> Audio.Frame -> Sample -> Audio
render config startOffset (Sample start filename offset envelope ratio) =
    resample2 config ratio startOffset start $
    applyEnvelope start envelope $
    Audio.File.readFrom (Audio.Seconds (RealTime.to_seconds offset))
        (Config.instrumentDbDir </> filename)

resample2 :: Resample.Config -> Signal.Signal -> Audio.Frame -> RealTime
    -> Audio -> Audio
resample2 config ratio startOffset start audio
    -- Don't do any work if it's close enough to 1.  This is likely to be
    -- common, so worth optimizing.
    | Just val <- Signal.constant_val_from start ratio,
            ApproxEq.eq closeEnough val 1 =
        -- resampleBy synchronizes, but File.readFrom doesn't.
        Audio.synchronizeToSize (Resample._now config)
            (Resample._chunkSize config) audio
    | otherwise = Resample.resampleBy2 config
        (Signal.shift (- (start + AUtil.toSeconds startOffset)) ratio)
        audio
        -- The resample always starts at 0 in the ratio, so shift it back to
        -- account for when the sample starts (start), and how far into the
        -- note (startOffset) I'm starting.
    where
    -- More or less a semitone / 100 cents / 10.  Anything narrower than this
    -- probably isn't perceptible.
    closeEnough = 1.05 / 1000


-- * old

-- | Evaluating the Audio could probably produce more exceptions...
realize :: Resample.Quality -> Sample -> (RealTime, Audio)
    -- ^ sample start time, and audio to render
realize quality (Sample start filename offset envelope ratio) = (start,) $
    resample quality ratio start $
    applyEnvelope start envelope $
    Audio.File.readFrom (Audio.Seconds (RealTime.to_seconds offset))
        (Config.instrumentDbDir </> filename)

resample :: Resample.Quality -> Signal.Signal -> RealTime -> Audio -> Audio
resample quality ratio start audio
    -- Don't do any work if it's close enough to 1.  This is likely to be
    -- common, so worth optimizing.
    | Just val <- Signal.constant_val_from start ratio,
            ApproxEq.eq closeEnough val 1 =
        audio
    | otherwise =
        Resample.resampleBy quality (Signal.shift (-start) ratio) audio
    where
    -- More or less a semitone / 100 cents / 10.  Anything narrower than this
    -- probably isn't perceptible.
    closeEnough = 1.05 / 1000

applyEnvelope :: RealTime -> Signal.Signal -> Audio -> Audio
applyEnvelope start sig
    | Just val <- Signal.constant_val_from start sig =
        if ApproxEq.eq 0.01 val 1 then id
            else Audio.gain (AUtil.dbToLinear (Num.d2f val))
    | otherwise = AUtil.volume $ Audio.linear $
        map (first RealTime.to_seconds) $ Signal.to_pairs sig
