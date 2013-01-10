{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Ui.ScoreTime (ScoreTime, to_double, double, suffix) where
import qualified Control.DeepSeq as DeepSeq
import qualified Data.Hashable as Hashable
import qualified Text.ParserCombinators.ReadP as ReadP
import qualified Text.Read as Read

import qualified Util.ApproxEq as ApproxEq
import Util.Control
import qualified Util.ForeignC as C
import qualified Util.Pretty as Pretty
import qualified Util.Serialize as Serialize

import qualified Ui.Util as Util


-- | Score time is the abstract unit of time, and its mapping to real time
-- is dependent on the score context.  ScoreTime units can be negative, but
-- blocks only display events at >=0 ScoreTime.
newtype ScoreTime = ScoreTime Double deriving
    ( DeepSeq.NFData, Num, Fractional, Real
    , RealFrac, Eq, Ord, Serialize.Serialize, Hashable.Hashable
    , ApproxEq.ApproxEq
    )

-- I could derive Storable, but technically speaking Double is not necessarily
-- the same as CDouble.
instance C.CStorable ScoreTime where
    sizeOf _ = C.sizeOf (undefined :: C.CDouble)
    alignment _ = C.alignment (undefined :: C.CDouble)
    poke p (ScoreTime d) = C.poke (C.castPtr p) (Util.c_double d)
    peek p = ScoreTime . Util.hs_double <$> C.peek (C.castPtr p)

instance Show ScoreTime where
    show (ScoreTime n) = show n ++ [suffix]

instance Read.Read ScoreTime where
    readPrec = do
        n <- Read.readPrec
        Read.lift ReadP.skipSpaces
        't' <- Read.get
        return (ScoreTime n)

instance Pretty.Pretty ScoreTime where
    pretty (ScoreTime p) = Pretty.show_float 3 p ++ [suffix]

to_double :: ScoreTime -> Double
to_double (ScoreTime p) = p

double :: Double -> ScoreTime
double = ScoreTime

-- | t is for time, since RealTime uses s for seconds
suffix :: Char
suffix = 't'
