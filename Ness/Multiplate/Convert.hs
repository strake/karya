module Ness.Multiplate.Convert where
import qualified Data.Text as Text

import qualified Perform.RealTime as RealTime
import qualified Synth.Shared.Control as Control
import qualified Synth.Shared.Note as Note
import Global
import Ness.Global
import qualified Ness.Multiplate as Multiplate
import qualified Ness.Multiplate.Patch as Patch


-- | Scale dynamic=1 to this.
maxAmp :: Newtons
maxAmp = 1000

type Error = Text

-- * implementation

convert :: Multiplate.Instrument -> [Note.Note] -> Either Error Multiplate.Score
convert inst notes = do
    strikes <- mapM (convertNote inst) notes
    let score = makeScore strikes
    let errors = Multiplate.verify inst score
    unless (null errors) $
        Left $ Multiplate.iName inst <> ": " <> Text.intercalate "; " errors
    return score


makeScore :: [Multiplate.Strike] -> Multiplate.Score
makeScore strikes = Multiplate.Score
    { sDecay = 6
    , sStrikes = strikes
    }

convertNote :: Multiplate.Instrument -> Note.Note
    -> Either Error Multiplate.Strike
convertNote inst note = first ((pretty note <> ": ")<>) $ do
    let object = Note.element note
    unless (object `elem` map Multiplate.pName (Multiplate.iPlates inst)) $
        Left $ "no object: " <> object
    let get c = tryJust ("no " <> pretty c) $ Note.controlVal c note
    dyn <- get Control.dynamic
    (x, y) <- (,) <$> get Patch.c_x <*> get Patch.c_y
    dur <- get Patch.c_duration
    return $ Multiplate.Strike
        { sObject = object
        , sStart = RealTime.to_seconds $ Note.start note
        , sDuration = dur
        , sPosition = (x, y)
        , sForce = dyn * maxAmp
        }
