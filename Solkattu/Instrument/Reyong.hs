-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE RecordWildCards, DeriveFunctor #-}
-- | Realize abstract solkattu Notes to concrete reyong 'Note's.
module Solkattu.Instrument.Reyong where
import qualified Derive.Expr as Expr
import qualified Solkattu.Realize as Realize
import qualified Solkattu.Sequence as Sequence
import qualified Solkattu.Solkattu as Solkattu

import Global


type SNote = Realize.SNote Stroke

note :: stroke -> Realize.SNote stroke
note = Sequence.Note . Realize.Note . Realize.stroke

-- Automatically infer two handed cek if they are isolated.
-- Maybe infer light byut if there is a note immediately afterwards?
data Stroke = N1 | N2 | N3 | N4 | N14 | Byut | Byong | CekC | CekO
    deriving (Show, Eq, Ord)

instance Solkattu.Notation Stroke where
    notation s = case s of
        N1 -> "1"
        N2 -> "2"
        N3 -> "3"
        N4 -> "4"
        N14 -> "i"
        Byut -> "b"
        Byong -> "o"
        CekC -> "k"
        CekO -> "x"

instance Pretty Stroke where pretty = Solkattu.notation

instance Expr.ToExpr Stroke where
    to_expr s = case s of
        N1 -> "n1"
        N2 -> "n2"
        N3 -> "n3"
        N4 -> "n4"
        N14 -> "n14"
        Byut -> "+"
        Byong -> "O"
        CekC -> "X"
        CekO -> "/"

instance Expr.ToExpr (Realize.Stroke Stroke) where to_expr = Realize.toExpr

data Strokes a = Strokes {
    r1 :: a, r2 :: a, r3 :: a, r4 :: a, i :: a
    , b :: a, o :: a, k :: a, x :: a
    } deriving (Functor, Show)

strokes :: Strokes Stroke
strokes = Strokes
    { r1 = N1
    , r2 = N2
    , r3 = N3
    , r4 = N4
    , i = N14
    , b = Byut
    , o = Byong
    , k = CekC
    , x = CekO
    }

notes :: Strokes SNote
notes = note <$> strokes

-- * patterns

type Patterns = Realize.Patterns Stroke

__ :: SNote
__ = Realize.rest

melodicNakatiku :: (Solkattu.Pattern, [SNote])
melodicNakatiku = (Solkattu.Nakatiku, [i, r3, i, r2, r3, i, r3, r2])
    where Strokes {..} = notes

melodicPatterns :: Patterns
melodicPatterns = Solkattu.check $ patterns
    [ (5, [r3, r2, r3, i, r2])
    , (6, [r3, r2, __, r3, i, r2])
    , (7, [r3, __, r2, __, r3, i, r2])
    , (8, [r3, r2, __, r3, __, i, __, r2])
    , (9, [r3, __, r2, __, r3, __, i, __, r2])
    ] where Strokes {..} = notes

rhythmicPatterns :: Patterns
rhythmicPatterns = Solkattu.check $ patterns
    [ (5, [b, __, o, __, __])
    , (6, [o, __, b, o, __, __])
    , (7, [x, __, x, __, o, __, __])
    , (8, [x, k, __, x, __, o, __, __])
    , (9, [x, k, __, x, __, b, o, __, __])
    ] where Strokes {..} = notes

patterns :: [(Sequence.Matra, [Realize.SNote Stroke])]
    -> Either Text (Realize.Patterns Stroke)
patterns = Realize.patterns . (melodicNakatiku:)
    . map (first Solkattu.PatternM)
