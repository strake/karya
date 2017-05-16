-- Copyright 2017 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.Solkattu.MridangamScore_test where
import qualified Data.Either as Either

import Util.Test
import qualified Derive.Solkattu.Korvai as Korvai
import qualified Derive.Solkattu.Mridangam as Mridangam
import qualified Derive.Solkattu.MridangamScore as MridangamScore
import qualified Derive.Solkattu.Realize as Realize

import Global


test_korvais = do
    equal [err | Left err <- map realize MridangamScore.all_korvais] []

realize :: Korvai.Korvai -> Either [Text] [[Realize.Note Mridangam.Stroke]]
realize korvai
    | not (null errors) = Left errors
    | not (null warnings) = Left warnings
    | otherwise = Right $ map (map snd) notes
    where
    (errors, results) = Either.partitionEithers $
        Korvai.realize Korvai.mridangam True korvai
    (notes, warnings) = second (filter (/="")) $ unzip results