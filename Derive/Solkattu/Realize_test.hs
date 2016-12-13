-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE RecordWildCards #-}
module Derive.Solkattu.Realize_test where
import qualified Data.Map as Map
import qualified Data.Text as Text

import Util.Test
import qualified Derive.Solkattu.Dsl as Dsl
import Derive.Solkattu.Dsl (ta, di, __)
import qualified Derive.Solkattu.Mridangam as M
import qualified Derive.Solkattu.Realize as Realize
import qualified Derive.Solkattu.Solkattu as Solkattu
import Derive.Solkattu.Solkattu (Note(..), Sollu(..))

import Global


test_realize = do
    let f = (Text.unlines *** show_strokes)
            . Realize.realize True mridangam
        sollu s = Sollu s Solkattu.NotKarvai Nothing
        mridangam = Realize.Instrument smap M.defaults
        smap = Realize.StrokeMap $ Map.fromList
            [ ([Ta, Din], map Just [k, od])
            , ([Na, Din], map Just [n, od])
            , ([Ta], map Just [t])
            , ([Din, Ga], [Just od, Nothing])
            ]
        k = M.Valantalai M.Ki
        t = M.Valantalai M.Ta
        od = M.Both M.Thom M.Din
        n = M.Valantalai M.Nam
    equal (f [Rest, sollu Ta, Rest, Rest, sollu Din]) (Right "__ k __ __ D")
    equal (f [Pattern 5, Rest, sollu Ta, sollu Din]) (Right "k t k n o __ k D")
    equal (f [sollu Ta, sollu Ta]) (Right "t t")
    equal (f [sollu Din, sollu Ga]) (Right "D __")
    equal (f [sollu Din, Rest, sollu Ga]) (Right "D __ __")
    left_like (f [sollu Din, sollu Din]) "sequence not found"

    -- An explicit stroke will replace just that stroke.
    equal (f [sollu Na,
            Sollu Din Solkattu.NotKarvai (Just (M.Valantalai M.Chapu))])
        (Right "n u")

test_realize_pattern = do
    let f patterns = Realize.realize True (Realize.Instrument mempty patterns)
        fmt = Text.unlines *** show_strokes
    equal (fmt $ f (M.families567 !! 0) [Pattern 5]) (Right "k t k n o")
    -- Patterns with a speed factor work.
    equal (fmt $ f (M.families567 !! 1) [Pattern 5])
        (Right "speed S2 k __ t __ k __ k t o __ speed S1")

    let p = expect_right $ f (M.families567 !! 1) [Pattern 5]
    -- TODO why all the underscores?
    equal (strip_emphasis $ Realize.format (Solkattu.adi_tala 4) p)
        "!k!_t_k_kt!o!_"

test_patterns = do
    let f = Realize.patterns
    let M.Strokes {..} = M.strokes
    left_like (f [(2, [k])]) "not a log2"
    left_like (f [(2, [k, M.__, k])]) "not a log2"
    left_like (f [(2, [k, Realize.Pattern 5])]) "expected Note or Rest"
    equal (second (const True) $ f [(2, [k, t])]) (Right True)

show_strokes :: [Realize.Note M.Stroke] -> Text
show_strokes = Text.unwords . map pretty

test_stroke_map = do
    let f = fmap (\(Realize.StrokeMap smap) -> Map.toList smap)
            . Realize.stroke_map
        M.Strokes {..} = M.strokes
    equal (f []) (Right [])
    equal (f [(ta <> di, [k, t])])
        (Right [([Ta, Di],
            [Just $ M.Valantalai M.Ki, Just $ M.Valantalai M.Ta])])
    left_like (f (replicate 2 (ta <> di, [k, t]))) "duplicate StrokeMap keys"
    left_like (f [(ta <> di, [k])]) "have differing lengths"
    left_like (f [(Dsl.tang <> Dsl.ga, [u, __, __])]) "differing lengths"
    left_like (f [(ta <> [Pattern 5], [k])]) "only have plain sollus"

test_format = do
    let f = strip_emphasis . Realize.format (Solkattu.adi_tala 4)
        n4 = [k, t, Dsl.__, n]
        M.Strokes {..} = M.strokes
    -- Emphasize every 4.
    equal (f n4) "!k! t _ n"
    equal (f (n4 <> n4)) "!k! t _ n !k! t _ n"
    -- Emphasis works in patterns.
    equal (f (n4 <> [Realize.Pattern 5] <> n4))
        "!k! t _ n !p5!------!--!k t _ !n!"
    -- Patterns are wrapped properly.
    equal (f (n4 <> [Realize.Pattern 5] <> n4 <> [Realize.Pattern 5]))
        "!k! t _ n !p5!------!--!k t _ !n! p5----\n\
        \!--!--"

strip_emphasis :: Text -> Text
strip_emphasis = Text.replace "\ESC[0m" "!" . Text.replace "\ESC[1m" "!"
