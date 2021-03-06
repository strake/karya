-- Copyright 2017 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE RecordWildCards #-}
module Solkattu.Notation_test where
import qualified Data.Tuple as Tuple

import Util.Test
import Solkattu.Dsl (su, sd, __)
import qualified Solkattu.DslSollu as DslSollu
import qualified Solkattu.Instrument.Mridangam as Mridangam
import qualified Solkattu.Korvai as Korvai
import Solkattu.Notation
import qualified Solkattu.Sequence as S
import qualified Solkattu.Solkattu as Solkattu
import qualified Solkattu.SolkattuGlobal as SolkattuGlobal
import qualified Solkattu.Tala as Tala

import Global


di, ta, ka, ki :: SequenceT Solkattu.Sollu
(di, ta, ka, ki) = (DslSollu.di, DslSollu.ta, DslSollu.ka, DslSollu.ki)

taka :: SequenceT Solkattu.Sollu
taka = ta <> ka

-- Many of the Notation functions are indirectly tested in Realize_test.

test_splitM = do
    equal (bimap (map pretty) (map pretty) $ splitM 1 taka)
        (["(1, After)(ta ka)"], ["(1, Before)(ta ka)"])

test_splitM_ = do
    let f matras = fmap (bimap extract extract) . splitM_either matras
        extract = map pretty . flattenGroups
    equal (f 1 (su taka <> di)) $ Right (["s+1(ta ka)"], ["di"])
    equal (f 1 (su (ta <> di <> ki <> ta) <> di)) $
        Right (["s+1(ta di)"], ["s+1(ki ta)", "di"])
    left_like (f 1 (sd ta <> ka)) "can't split"

    -- split rests
    equal (f 1 (sd __ <> ka)) $ Right (["__"], ["__", "ka"])
    equal (f 3 (sd (sd __) <> ka)) $ Right (["s-1(__)", "__"], ["__", "ka"])

test_takeDrop = do
    let tdgn = mconcat [ta, DslSollu.din, DslSollu.gin, DslSollu.na]
    let extract = map pretty
    equal (extract $ dropM_ 0 (takeM 2 tdgn)) ["(2, After)(ta din gin na)"]
    equal (extract $ dropM_ 1 (takeM 2 tdgn)) ["din"]
    equal (extract $ dropM_ 2 (takeM 3 tdgn)) ["gin"]
    equal (extract $ dropM_ 2 (takeM 2 tdgn)) []

test_spaceM = do
    let f = sum . map (S.noteFmatra S.defaultTempo) . spaceM Solkattu.Rest
    equal (f 0) 0
    equal (f 1) 1
    equal (f 3) 3
    equal (f (3/4)) (3/4)
    throws (f (1/3)) "not a binary multiple"

test_replaceStart = do
    let f prefix = map pretty . replaceStart prefix
    equal (f di (ta<>ki<>ta)) ["di", "ki", "ta"]
    equal (f di (su taka <> ki)) ["di", "ki"]
    -- split rests
    throws (f di (sd ta)) "can't split"

test_align = do
    let f dur = map pretty . __a dur
    equal (f 1 ta) ["s-1(__)", "__", "ta"]

flattenGroups :: [S.Note g a] -> [S.Note () a]
flattenGroups = S.flattenGroups

realizeKorvai :: SolkattuGlobal.StrokeMap Mridangam.Stroke
    -> SolkattuGlobal.Sequence -> Either Text [(Text, S.Duration)]
realizeKorvai strokes = realize . makeKorvai strokes

makeKorvai :: SolkattuGlobal.StrokeMap Mridangam.Stroke
    -> SolkattuGlobal.Sequence -> SolkattuGlobal.Korvai
makeKorvai strokes seq = korvai
    where
    korvai = SolkattuGlobal.korvaiS1 Tala.adi_tala
        (SolkattuGlobal.makeMridangam0 strokes)
        seq

realize :: SolkattuGlobal.Korvai -> Either Text [(Text, S.Duration)]
realize = extract . head . Korvai.realize Korvai.mridangam False
    where
    extract (Left err) = Left err
    extract (Right (strokes, _err)) = Right $ extractStrokes strokes
    extractStrokes = map (Tuple.swap . second pretty) . S.flattenedNotes
        . S.withDurations
