{-# LANGUAGE MagicHash #-}
-- | Miscellaneous functions on numbers.  Things that could have gone in
-- Numeric.
module Util.Num where
import qualified Data.Bits as Bits
import qualified Data.Fixed as Fixed
import qualified GHC.Prim as Prim
import qualified GHC.Types as Types
import qualified Numeric


-- * show

-- | Show a word as binary.
--
-- Warning: for some reason, Integer is an instance of Bits, but bitSize will
-- crash.
binary :: (Bits.Bits a) => a -> String
binary b = map extract [bits-1, bits-2 .. 0]
    where
    extract i = if Bits.testBit b i then '1' else '0'
    bits = Bits.bitSize b

hex :: (Integral a, Show a) => a -> String
hex n = Numeric.showHex n ""

-- * transform

-- | Clamp a value to be between @low@ and @high@.
clamp :: (Ord a) => a -> a -> a -> a
clamp low high = min high . max low

-- | Confine the given value lie between the first two arguments, but using
-- modulus, not clamping.
restrict :: (Real a) => a -> a -> a -> a
restrict low high
    | high == low = const low -- avoid dividing by 0 in fmod
    | otherwise = (+low) . (`fmod` (high-low)) . subtract low

in_range :: (Ord a) => a -> a -> a -> Bool
in_range low high x = low <= x && x < high

-- | Scale @v@, which is between 0 and 1 inclusive, to be between @low@ and
-- @high@.  If @v@ is not in the 0--1 range, the result will be out of the
-- low--high range.
{-# INLINEABLE scale #-}
{-# SPECIALIZE scale :: Double -> Double -> Double -> Double #-}
scale :: (Eq a, Num a) => a -> a -> a -> a
scale low high v
    -- Some calls to scale are likely to have 0 or 1.  If low and high are
    -- complicated expressions its nice to avoid evaluating them.
    | v == 0 = low
    | v == 1 = high
    | otherwise = v * (high-low) + low

-- | Normalize @v@, which is between @low@ and @high@ inclusive, to be between
-- 0 and 1.  As with 'scale', if @v@ is not in range, the result will not be
-- in range either.
{-# INLINEABLE normalize #-}
{-# SPECIALIZE normalize :: Double -> Double -> Double -> Double #-}
normalize :: (Eq a, Fractional a) => a -> a -> a -> a
normalize low high v
    | low == high && v == low = 0 -- avoid a divide by zero
    | v == high = 1
    | otherwise = (v-low) / (high-low)

infixl 7 `fmod` -- match `mod`

-- | fmod is in a bizarre place.
{-# SPECIALIZE fmod :: Double -> Double -> Double #-}
fmod :: (Real a) => a -> a -> a
fmod = Fixed.mod'

-- | realToFrac doesn't preserve the special float values and is inefficient.
--
-- There are some RULEs for this, but they aren't reliable.
d2f :: Double -> Float
d2f (Types.D# d) = Types.F# (Prim.double2Float# d)

f2d :: Float -> Double
f2d (Types.F# f) = Types.D# (Prim.float2Double# f)

-- | Conversion that clamps at INT_MIN / INT_MAX.
d2i :: Double -> Int
d2i d = floor (clamp min_int max_int d)
    where
    max_int = fromIntegral (maxBound :: Int)
    min_int = fromIntegral (minBound :: Int)
