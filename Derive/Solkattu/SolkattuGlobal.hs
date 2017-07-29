-- Copyright 2017 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE RecordWildCards #-}
-- | Global imports for solkattu score modules.
module Derive.Solkattu.SolkattuGlobal (
    module Derive.Solkattu.SolkattuGlobal
    , module Derive.Solkattu.Dsl
    , module Derive.Solkattu.DslSollu
) where
import Prelude hiding ((.))

import qualified Util.CallStack as CallStack
import Derive.Solkattu.Dsl
import Derive.Solkattu.DslSollu
import qualified Derive.Solkattu.Instrument.KendangTunggal as KendangTunggal
import qualified Derive.Solkattu.Instrument.Mridangam as Mridangam
import qualified Derive.Solkattu.Instrument.Reyong as Reyong
import qualified Derive.Solkattu.Instrument.Sargam as Sargam
import qualified Derive.Solkattu.Korvai as Korvai
import qualified Derive.Solkattu.Realize as Realize
import qualified Derive.Solkattu.Sequence as Sequence
import qualified Derive.Solkattu.Solkattu as Solkattu
import qualified Derive.Solkattu.Tala as Tala

Mridangam.Strokes {..} = Mridangam.notes


type Sequence = Seq Korvai.Stroke
type Seq stroke = [Sequence.Note (Solkattu.Note stroke)]

-- * fragments

tdgnt, td_gnt, t_d_gnt :: Seq stroke
tdgnt = ta.din.gin.na.thom
td_gnt = ta.din.__.gin.na.thom
t_d_gnt = ta.__.din.__.gin.na.thom

takadinna :: Seq stroke
takadinna = ta.ka.din.na

takita :: Seq stroke
takita = ta.ki.ta

kita :: Seq stroke
kita = ki.ta

taka :: Seq stroke
taka = ta.ka

on :: Mridangam.SNote
on = o & n

-- * instruments

type MStrokes = [(Seq Mridangam.Stroke, [Mridangam.SNote])]

make_mridangam :: CallStack.Stack => MStrokes -> Korvai.StrokeMaps
make_mridangam strokes = make_mridangam0 (_standard_mridangam ++ strokes)

make_mridangam0 :: CallStack.Stack => MStrokes -> Korvai.StrokeMaps
make_mridangam0 strokes = mempty
    { Korvai.inst_mridangam = check $
        Mridangam.instrument strokes Mridangam.default_patterns
    }

make_kendang1 :: CallStack.Stack =>
    [(Seq KendangTunggal.Stroke, [KendangTunggal.SNote])]
    -> Korvai.StrokeMaps
make_kendang1 strokes = mempty
    { Korvai.inst_kendang_tunggal = check $
        KendangTunggal.instrument strokes KendangTunggal.default_patterns
    }

make_reyong :: CallStack.Stack => [(Seq Reyong.Stroke, [Reyong.SNote])]
    -> Korvai.StrokeMaps
make_reyong strokes = mempty
    { Korvai.inst_reyong = check $
        Reyong.instrument strokes Reyong.rhythmic_patterns
    }

make_sargam :: CallStack.Stack => [(Seq Sargam.Stroke, [Sargam.SNote])]
    -> [(Solkattu.Pattern, [Realize.SNote Sargam.Stroke])]
    -> Korvai.StrokeMaps
make_sargam strokes patterns = mempty
    { Korvai.inst_sargam = check $
        Sargam.instrument strokes (check $ Realize.patterns patterns)
    }

korvai1 :: CallStack.Stack => Tala.Tala -> Korvai.StrokeMaps -> Sequence
    -> Korvai
korvai1 tala inst seq = Korvai.korvai tala inst [seq]

korvai :: CallStack.Stack => Tala.Tala -> Korvai.StrokeMaps -> [Sequence]
    -> Korvai
korvai = Korvai.korvai

-- | 'make_mridangam' gives this to all mridangam stroke maps.
_standard_mridangam :: [(Seq stroke, [Mridangam.SNote])]
_standard_mridangam =
    [ (takadinna, [k, o, o, k])
    , (tdgnt, [k, t, k, n, o])
    , (dheem, [od])
    ]
    where Mridangam.Strokes {..} = Mridangam.notes

vary :: Korvai -> Korvai
vary = Korvai.vary $ Solkattu.vary (Solkattu.variations [Solkattu.standard])
