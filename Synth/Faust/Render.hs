-- Copyright 2018 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE DataKinds #-}
-- | Render FAUST instruments.
module Synth.Faust.Render where
import qualified Control.Monad.Trans.Resource as Resource
import qualified Data.Map as Map
import qualified Data.Vector.Storable as V
import qualified GHC.TypeLits as TypeLits
import qualified Streaming.Prelude as S

import qualified Util.Audio.Audio as Audio
import qualified Util.CallStack as CallStack
import qualified Util.Seq as Seq

import qualified Perform.RealTime as RealTime
import qualified Synth.Faust.DriverC as DriverC
import qualified Synth.Lib.AUtil as AUtil
import Synth.Lib.Global
import qualified Synth.Shared.Control as Control
import qualified Synth.Shared.Note as Note
import qualified Synth.Shared.Signal as Signal

import Global


-- | Render notes belonging to a single FAUST patch.  Since they render on
-- a single element, they should either not overlap, or be ok if overlaps
-- cut each other off.
renderPatch :: DriverC.Patch -> [Note.Note] -> Audio
renderPatch patch notes =
    maybe id AUtil.volume amp $ interleave $ render patch inputs final decay
    where
    inputs = renderControls (filter (/=Control.amplitude) controls) notes
    controls = DriverC.getControls patch
    amp = renderControl notes Control.amplitude
    final = maybe 0 Note.end (Seq.last notes)
    decay = 2

interleave :: NAudio -> Audio
interleave naudio = case Audio.interleaved naudio of
    Right audio -> audio
    -- All faust instruments are required to have 1 or 2 outputs.  This should
    -- have been verified by DriverC.getParsedMetadata.
    Left err -> Audio.throw $ "expected 1 or 2 outputs: " <> err

-- | Render a FAUST instrument incrementally.
--
-- Chunk size is determined by the size of the 'NAudio' chunks, or
-- Audio.chunkSize if they're empty or run out.  The inputs will go to zero
-- if they end before the given time.
render :: DriverC.Patch -> NAudio -> RealTime -- ^ logical end time
    -> RealTime
    -- ^ max decay, force an end if the signal hasn't gone to zero before this
    -> NAudio
render patch inputs end decay = Audio.NAudio (DriverC.patchOutputs patch) $ do
    (key, inst) <- lift $
        Resource.allocate (DriverC.initialize patch) DriverC.destroy
    let nstream = Audio._nstream (Audio.zeroPadN inputs)
    Audio.loop1 (0, nstream) $ \loop (start, inputs) -> do
        -- Audio.zeroPadN should have made this infinite.
        (controls, nextInputs) <-
            maybe (CallStack.errorIO "end of endless stream") return
                =<< lift (S.uncons inputs)
        result <- render1 inst controls start
        case result of
            Nothing -> Resource.release key
            Just start -> loop (start, nextInputs)
    where
    render1 inst controls start = do
        outputs <- liftIO $ DriverC.render inst controls
        S.yield outputs
        case outputs of
            [] -> CallStack.errorIO "dsp with 0 outputs"
            output : _
                | frames == 0 || blockEnd >= final + maxDecay
                        || blockEnd >= final && isBasicallySilent output ->
                    return Nothing
                | otherwise -> return $ Just blockEnd
                where
                blockEnd = start + frames
                frames = Audio.Frame $ V.length output
    final = AUtil.toFrames end
    maxDecay = AUtil.toFrames decay

isBasicallySilent :: V.Vector Audio.Sample -> Bool
isBasicallySilent _samples = False -- TODO RMS < -n dB

-- | Render the supported controls down to audio rate signals.
renderControls :: [Control.Control]
    -- ^ controls expected by the instrument, in the expected order
    -> [Note.Note] -> NAudio
renderControls controls notes =
    Audio.nonInterleaved $
        map (fromMaybe Audio.silence . renderControl notes) controls

renderControl :: (Monad m, TypeLits.KnownNat rate)
    => [Note.Note] -> Control.Control -> Maybe (Audio.Audio m rate 1)
renderControl notes control
    | control == Control.gate = Just $ Audio.linear $ gateBreakpoints notes
    | null bps = Nothing
    | otherwise = Just $ Audio.linear bps
    where bps = controlBreakpoints control notes

-- | Make a signal which goes to 1 for the duration of the note.
--
-- Disabled for now: It won't go to 0 for touching or overlapping notes.  If
-- a gate transition is required to trigger an attack, presumably the notes
-- should be shorter duration, such as 0 if it's percussion-like.
gateBreakpoints :: [Note.Note] -> [(Double, Double)]
gateBreakpoints = map (first RealTime.to_seconds) . go
    where
    go [] = []
    go (n : ns) =
        (Note.start n, 0) : (Note.start n, 1) : (Note.end end, 0) : go rest
        where (end, rest) = (n, ns)

    -- TODO this combines touching notes as documented above, but it turns out
    -- I rely on not doing that.  Either I should make gate always do that and
    -- be explicitly percussive, or have karya set percussive events to
    -- dur = 0.
    -- go (n : ns) =
    --     (Note.start n, 0) : (Note.start n, 1)
    --     : (Note.end end, 1) : (Note.end end, 0)
    --     : go rest
    --     where
    --     (end : rest) = dropUntil (\n1 n2 -> Note.end n1 < Note.start n2)
    --         (n:ns)

-- | Drop until this element and the next one matches.
dropUntil :: (a -> a -> Bool) -> [a] -> [a]
dropUntil match = go
    where
    go [] = []
    go [x] = [x]
    go (x1 : xs@(x2 : _))
        | match x1 x2 = x1 : xs
        | otherwise = go xs

controlBreakpoints :: Control.Control -> [Note.Note] -> [(Double, Double)]
controlBreakpoints control = concat . mapMaybe get . Seq.zip_next
    where
    get (note, next) = do
        signal <- Map.lookup control (Note.controls note)
        return $ map (first RealTime.to_seconds) $ Signal.to_pairs $
            maybe id (Signal.clip_after_keep_last . Note.start) next $
            Signal.clip_before (Note.start note) signal
