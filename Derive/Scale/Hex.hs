module Derive.Scale.Hex where
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Ratio as Ratio
import Data.Ratio ((%))
import qualified Data.Vector as Vector

import Util.Control
import qualified Util.Num as Num
import qualified Derive.Scale as Scale
import qualified Derive.Scale.JustScales as JustScales
import qualified Derive.Scale.TheoryFormat as TheoryFormat

import qualified Perform.Pitch as Pitch


scales :: [Scale.Scale]
scales =
    [ JustScales.make_scale (Pitch.ScaleId "hex")
        (scale_map (TheoryFormat.letters pc_per_octave)) doc
    , JustScales.make_scale (Pitch.ScaleId "hex-r")
        (scale_map (TheoryFormat.cipher pc_per_octave relative_fmt)) doc
    ]

doc :: Text
doc = "This is a family of 6 note just scales, based on Erv Wilson's hexanies.\
    \ The keys look like `a-159b-1`.  The `a` means that in absolute naming,\
    \ unity is on `a` (in relative naming, unity is always `1`).  `159b` means\
    \ the hexany is built on 1, 5, 9, 11.  The trailing `1` means unity is\
    \ assigned to the first ratio produced. For example, if you modulate to the\
    \ 5th scale degree, you would change the key to `a-159b-6` and set\
    \ `%just-base` accordingly.\n"

pc_per_octave :: Int
pc_per_octave = 6

scale_map :: TheoryFormat.Format -> JustScales.ScaleMap
scale_map = JustScales.scale_map keys default_key

relative_fmt :: TheoryFormat.RelativeFormat TheoryFormat.Tonic
relative_fmt = JustScales.make_relative_fmt keys default_key

default_key :: JustScales.Key
Just default_key = Map.lookup (Pitch.Key "a-1357-1") keys

keys :: JustScales.Keys
keys = JustScales.make_keys (take pc_per_octave TheoryFormat.letter_degrees)
    key_ratios

key_ratios :: [(Text, JustScales.Ratios)]
key_ratios = concatMap make_hexany
    [ [1, 3, 5, 7]
    , [1, 3, 5, 9]
    , [1, 3, 7, 9]
    , [1, 3, 5, 11]
    , [1, 3, 7, 11]
    , [1, 3, 9, 11]
    , [1, 5, 7, 9]
    , [1, 5, 9, 11]
    ]

hexany_ratios :: [[Int]] -> [[Ratio]]
hexany_ratios = map (snd . head . make_ratios)

make_hexany :: [Int] -> [(Text, JustScales.Ratios)]
make_hexany xs =
    [ (show_roots xs <> "-" <> showt (n+1), Vector.fromList ratios)
    | (n, ratios) <- make_ratios xs
    ]

show_roots :: [Int] -> Text
show_roots = txt . mapMaybe Num.show_higit

make_ratios :: [Int] -> [(Int, [Ratio])]
make_ratios =
    map (second (List.sort . map reduce_octave)) . choose_unity
    . map (uncurry (*)) . permute . map (%1)
    where
    choose_unity xs = [(n, map (/x) xs) | (n, x) <- zip [0..] xs]

permute :: [a] -> [(a, a)]
permute (x:xs) = [(x, y) | y <- xs] ++ permute xs
permute [] = []

type Ratio = Ratio.Ratio Int

reduce_octave :: Ratio -> Ratio
reduce_octave ratio
    | ratio >= 2 = reduce_octave (ratio / 2)
    | ratio < 1 = reduce_octave (ratio * 2)
    | otherwise = ratio
