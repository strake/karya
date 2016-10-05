-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Korvais expressed in "Derive.Solkattu.Dsl".
module Derive.Solkattu.Score where
import Prelude hiding ((.), (^), repeat)
import qualified Data.List as List
import qualified Data.Text.IO as Text.IO

import qualified Util.CallStack as CallStack
import Derive.Solkattu.Dsl
import qualified Derive.Solkattu.KendangBaliTunggal as KendangBaliTunggal
import qualified Derive.Solkattu.Korvai as Korvai
import qualified Derive.Solkattu.Mridangam as Mridangam
import qualified Derive.Solkattu.Realize as Realize
import qualified Derive.Solkattu.Solkattu as Solkattu

import Global


-- * chatusra nadai

c1s :: [Korvai]
c1s = korvais (adi 4) mridangam
    [            theme 2 0 . p5
      . dropM 2 (theme 2 1) . p6 . p6
      . dropM 4 (theme 2 2) . tri p7 . tri p6 . tri p5

    , let tadin_ = ta.__.din.__.__ in
                 theme 3 0 . p5 . tadin_
      . dropM 3 (theme 3 1) . p6 . p6 . tadin_
      . dropM 6 (theme 3 2) . trin tadin_ (tri p7) (tri p6) (tri p5)

    ,            theme 4 0 . pat7 . dheem!u . __4
      . dropM 4 (theme 4 1) . repeat 2 pat8 . dheem!u . __4
      . dropM 8 (theme 4 2)
        . trin (dheem . __4) (tri pat9) (tri pat8) (tri pat7)

    ]
    where
    theme gap1 gap2 = ta . __n gap1 . dit . __n gap1 . ta.ka.din.na.din
        . tri (ta . __n (gap2+1) . din . __n gap1)
    mridangam = make_mridangam
        [ (ta.dit, [k, t])
        , (dit, [k])
        , (ta.ka.din.na.din, [k, o, o, k, o])
        , (ta.din, [k, od])
        -- for pat7 -- pat9
        , (ta.ka, [k, p])
        ]
    pat7 = ta.ka.p5
    pat8 = ta.ka.__.p5
    pat9 = ta.__.ka.__.p5

c2_yt1 :: Korvai
c2_yt1 = korvai (adi 4) mridangam $
    -- tat.__.dit.__.ta.ka.din.na.thom.__.tat.__.din.__4
    --       .dit.__.ta.ka.din.na.thom.__.tat.__.din.__4
    --              .ta.ka.din.na.thom.__.tat.__.din.__4
    --                    .din.na.thom.__.tat.__.din.__4
    --                           .thom.__.tat.__.din.__4
    --                                   .tat.__.din.__4 -- ta ka din
    --                                          .din.__4
    -- TODO ... `replace` (tat.__.din.__4) (ta.ka.din.__4)
    reduceTo 2 4 (tat.__.dit.__.ta.ka.din.na.thom.__.tat.__.din.__4)
    . tri p6 . tam.__ . tri p6 . tam!i.__ . tri p6
    where
    mridangam = make_mridangam
        [ (tat.dit, [k, t])
        , (ta.ka.din.na, [k, o, o, k])
        , (din.na, [o, k])
        , (thom.tat.din, [o&n, k, od])
        , (dit, [k])
        , (tat, [k])
        , (din, [od])
        ]

c_16_09_28 :: Korvai
c_16_09_28 = korvai (adi 4) mridangam $
    tat.__.dit.__.kitakina . nakatiku . tri_ __ (na.ka.ta.ka.din.na.dheem) . __6
          .dit.__.kitakina . nakatiku . tri_ __       (ta.ka.din.na.dheem) . __6
                 .kitakina . nakatiku . tri_ __              (ta.ka.dheem) . __6
    . tri (p6 . ta.ka.p6 . ta.ka.na.ka.p6)
    where
    kitakina = ki.ta.ki.na.ta.ki.ta.ka
    nakatiku = na.ka.ti.ku.ta.ri.ki.ta
    mridangam = make_mridangam
        [ (tat.dit, [k&p, t])
        , (dit, [k])
        , (kitakina, [k, t, k, n, o, k, t&o, k])
        , (nakatiku, [n, p, u, p, k, t, p, k])
        , (na.ka, [n, p])
        , (ta.ka.din.na, [k, o, o, k])
        , (ta.ka.dheem, [p, k, o&d])
        , (ta.ka, [k, p])
        , (ta.ka.na.ka, [k, p, n, p])
        , (dheem, [o&d])
        ]


chatusrams :: [Korvai]
chatusrams = concat
    [ c1s, [c2_yt1, c_16_09_28]
    ]

-- * kanda nadai

make_k1 :: Sequence -> Korvai
make_k1 = korvai (adi 5) k1_mridangam

make_k1_1 :: Sequence -> Sequence -> Korvai
make_k1_1 pt gap = make_k1 $
      at0 . k1_a  . __ . ta . din . __n (10 - pdur) . pt
    . atX . k1_a' . __ . ta . din . __n (10 - pdur) . pt
    . at0 . ta . __ . di . __ . ki . ta . __ . gap
    .       ta . ka . di . __ . ki . ta . __ . gap
    . case pdur of
        5 -> p567 end_gap
        6 -> p666 end_gap
        _ -> p765 end_gap
    where
    pdur = duration_of pt
    end_gap = __n (5 - duration_of gap)

k1_1s :: [Korvai]
k1_1s = [make_k1_1 p g | g <- gaps, p <- [pat 5, pat 6, pat 7]]
    where gaps = [thom.__.ta.__, thom.__3, thom.__, thom, mempty]

k1_2 :: Korvai
k1_2 = make_k1 $
      at0 . k1_a  . __ . ta_din_ . p7
    . atX . k1_a' . __ . ta_din_ . p7
    . at0 . k1_a . __ . k1_a' . __
          . ta_din_ . tri p7
          . ta_din_ . tri (tadin_ . p7)
          . ta_din_ . tri (tadin_ . tadin_ . p7)
    where
    p7 = ta.ka.p5
    ta_din_ = ta.__.din.__
    tadin_ = ta.din.__

k1_3 :: Korvai
k1_3 = make_k1 $
      k1_a  . __ . tata_dindin_ . p6 . __
    . k1_a' . __ . tata_dindin_ . ta.ka.p6 . __
    . k1_a . __ . k1_a' . __ . tata_dindin_
    . tri_ __ (ta.ka.ti.ku.p6)
    . tri_ __ (ta.ka.p6)
    . tri_ __ p6
    where
    tata_dindin_ = ta.__.ta.__3.din.__.din.__3

k1_a, k1_a' :: Sequence
k1_a  = ta.__.di.__.ki.ta.__.thom
k1_a' = ta.ka.di.__.ki.ta.__.thom

k1_mridangam :: Korvai.Realizations
k1_mridangam = make_mridangam
    [ (ta, [k])
    , (ta.ka, [k, p])
    , (ta.ka.ti.ku, [k, p, n, p])
    , (ta.di.ki.ta, [k, t, k, n])
    , (ta.ka.di.ki.ta, [k, p, t, k, n])
    , (din, [od])
    ]

k2 :: Bool -> Korvai
k2 chatusram_transition = korvai (adi 5) k1_mridangam $
      din.__3 . p5.tam.__4.p6.ta.__
    . din.__3 . p5.tam.__4.p6.ta.__.ta.__
    . din.__3 . p5
    . if chatusram_transition
        then nadai 4 . tri (ta.ta.__.p5)
        else tam.__4 . tri_ __5 p6
    -- p6 can also be k-t---ktkto-
    -- development is din_3.p5.ta.__.din

k3s :: [Korvai]
k3s = korvais (adi 5) mridangam
    [   dit . __  . tangkita . dit   . tat . din^2 . __
      . dit . tat . tangkita . dit^4 . tat . din . __
      . ta . __ . dit . tat . din . __
      . ta^6.ka.dit.tat.din.__
      . ta.ki.ta.ta.ki^0.ta
      . p6.__.p6.p6.__.p6.p6.p6 -- utarangam

    ,   dit . __  . tangkita . din . __4
      . dit . tat . tangkita . din . __4
      . dit . __  . tangkita . din . __
      . dit . tat . tangkita . din . __
      . dit . __  . tangkita
      . dit . tat . tangkita
      . tri_ __ p6
    ]
    where
    tangkita = s2 (tang . __ . kitataka . tarikitataka)
    kitataka = ki.ta.tha.ka
    tarikitataka = ta.ri.kitataka
    mridangam = make_mridangam
        [ (dit, [pk])
        , (ta.ki.ta, [p, k, od])
        , (ta.ka, [p, k])
        , (dit.tat, [p, k])
        , (kitataka, [p, k, n, p])
        , (tarikitataka, [u, p, k, t, p, k])
        , (din, [od])
        , (ta, [k])
        ]

kandams :: [Korvai]
kandams = concat
    [ k1_1s
    , [k1_2, k1_3]
    , [k2 False, k2 True]
    , k3s
    ]

-- * tisra nadai

t_sarva1 :: (Sequence, Sequence)
t_sarva1 =
    ( dhom.ka.na.na.di.mi . na.mi.na.na.di.mi
      . na.mi.na.na.di.mi . na.mi.na.na.di.mi
    , ta  .__.ta.ta.ta.__ . ta.__.ta.ta.ta.__
    . ta  .__.__.__.__.__ . __.__.ta.ta.ta.__
    )
    -- dhom is either [o] or [o, t]
    -- TODO I need a better way to write sarva laghu.  The problem is the thoms
    -- are implicit.

t1s :: [Korvai]
t1s = korvais (adi 6) mridangam
    [ reduce (tat.__.dit.__.ta.ka.din.na.din.__.__)   . utarangam p5
    , reduce (tat.__.dit.__.ta.ka.din.na.din.__)      . utarangam p6
    , reduce (tat.__.dit.__.ta.ka.din.na.din!p)       . utarangam p7
    , reduce (tat.__.dit.__.ta.ka.din.na)             . utarangam p8
    , reduce (tat.__.dit.__.ta.ka.din)                . utarangam p9
    ]
    where
    utarangam = tri_ (tang.__.ga)
    reduce = reduce3 2 mempty
    mridangam = make_mridangam
        [ (tat.dit, [k, t])
        , (dit, [k])
        , (ta.ka.din.na, [k, o, o, k])
        , (ta.ka.din, [k, o, o])
        , (din, [od])
        , (tang.ga, [u, __])
        ]

t2s :: [Korvai]
t2s = korvais (adi 6) mridangam
    [ reduce (tat.__.dit.__.ta.ka.din.na.dheem.__5) . tri p5
    , reduce (tat.__.dit.__.ta.ka.din.na.dheem.__4) . tri p6
    , reduce (tat.__.dit.__.ta.ka.din.na.dheem.__3) . tri p7
    , reduce (tat.__.dit.__.ta.ka.din.na.dheem.__)  . tri (ta.din.__.p5)
    , reduce (tat.__.dit.__.ta.ka.din.na.din!p)     . tri (ta.__.din.__.p5)
    , reduce (tat.__.dit.__.ta.ka.din.na)           . tri (ta.ka.ta.din.__.p5)
    , reduce (tat.__.dit.__.ta.ka.din)             . tri (ta.ka.__.ta.din.__.p5)

    , reduce (tat.__.dit.__.ta.ka.din) . tri (ta.dinga.p7)
    , let tadin_ n = repeat n (ta.din.__) in
      reduce (tat.__.dit.__.ta.ka.din)
        . tadin_ 1 . p5 . tadin_ 2 . p5 . tadin_ 3 . p5

    , reduce (tat.__.dit.__.ta.ka.din) . tri (ta.din.__.p8)
    ]
    where
    reduce = reduce3 2 mempty
    mridangam = make_mridangam
        [ (tat.dit, [k, t])
        , (dit, [k])
        , (ta.ka.din.na, [k, o, o, k])
        , (ta.ka.din, [k, o, o])
        , (tha, [p])
        , (ta.ka, [k, p])
        , (dheem, [od])
        , (din, [od])
        , (ta.din.ga, [k, od, __])
        , (ta.din, [k, od])
        ]

t3s :: [Korvai]
t3s = korvais (adi 6) mridangam
    [ reduce (tat.__.dit.__.ta.ka.din.na.__.ka.din.na.dinga) . utarangam p5
    , reduce (tat.__.dit.__.ta.ka.din.na.__.dinga) . utarangam p6
    , reduce (tat.__.dit.__.ta.ka.din.na.__) . utarangam p7

    , variation (5, 5, 5) (6, 6, 6) (7, 7, 7)
    , variation (7, 7, 7) (6, 6, 6) (5, 5, 5)
    , variation (5, 6, 7) (5, 6, 7) (5, 6, 7)
    , variation (7, 6, 5) (7, 6, 5) (7, 6, 5)
    , variation (5, 6, 7) (6, 6, 6) (7, 6, 5)
    ]
    -- tat.__.dit.__.ta.ka.din.na.__.ka.din.na.dinga
    --       .dit.__.ta.ka.din.na.__.ka.din.na.dinga
    --              .ta.ka.din.na.__.ka.din.na.dinga
    -- tat.__.dit.__.ta.ka.din.na.__.dinga
    --       .dit.__.ta.ka.din.na.__.dinga
    --              .ta.ka.din.na.__.dinga
    where
    utarangam p = trin (tang.__.ga) (tri p) (tri_ __ p) (tri_ __3 p)
    variation (a1, a2, a3) (b1, b2, b3) (c1, c2, c3) =
        reduce (tat.__.dit.__.ta.ka.din.na.__.dinga)
        . trin (tang.__.ga)
            (trin mempty (pat a1) (pat a2) (pat a3))
            (trin __ (pat b1) (pat b2) (pat b3))
            (trin __3 (pat c1) (pat c2) (pat c3))
    reduce = reduce3 2 mempty
    mridangam = make_mridangam
        [ (tat.dit, [k, t])
        , (dit, [k])
        , (ta.ka.din.na, [k, o, o, k])
        , (ka.din.na, [o, o, k])
        , (din, [od])
        , (dinga, [od, __])
        , (tang.ga, [u, __])
        ]

t4s :: [Korvai]
t4s = korvais (adi 6) mridangam $ map (purvangam.)
    [ let tdgnt = [ta, din, gin, na, thom] in
        mconcatMap (.__3) tdgnt . mconcatMap (.__) tdgnt
        . tri_ __ (mconcat tdgnt)
    , mconcatMap (.__3) [ta, din, gin, na, thom]
        . tri (ta.__.din.__.gin.__.na.__.thom)
    , tri_ (dheem.__3) (ta.din.__.ta.__.din.__.p5)
    , tri_ (dheem.__3) (p5.ta.__.din.__.ta.din.__)
    , p123 p6 (dheem.__3)

    , p123 p5 (tat.__3.din.__3)
    , let dinga s = din!s . __ . ga
        in p5.dinga u . ta.ka . p5.p5. dinga i . ta.ka.ti.ku . p5.p5.p5
    , tri (tat.dinga . tat.__.dinga.p5)
    ]
    where
    p123 p sep = trin sep p (p.p) (p.p.p)
    purvangam = tri (ta_katakita . din.__6)
    ta_katakita = ta.__.ka.ta.ki.ta.ta.ka.ta.ka.din.na
    mridangam = make_mridangam
        [ (ta.din.gin.na.thom, [k, t, k, n, o])
        , (ta.ka.(ta.ki.ta).(ta.ka), [k, p, k, t, k, t, k])
        , (ta.ka.din.na, [k, o, o, k])
        , (ta.din, [k, od])
        , (dheem, [u])
        , (din, [od])
        , (tat, [k])
        , (ta.ka.ti.ku, [k, p, n, p])
        , (ta.ka, [k, p])
        , (dinga, [od, p])
        ]

tisrams :: [Korvai]
tisrams = concat
    [ t1s, t2s, t3s
    ]

-- * vary

vary :: Korvai -> [Korvai]
vary = Korvai.vary $ Solkattu.vary (Solkattu.variations [Solkattu.standard])

-- * realize

make_mridangam :: CallStack.Stack => [(Sequence, [Mridangam.Note])]
    -> Korvai.Realizations
make_mridangam strokes = mempty
    { Korvai.mridangam = check $ Mridangam.instrument strokes Mridangam.defaults
    }

make_kendang1 :: CallStack.Stack =>
    [(Solkattu.Sequence KendangBaliTunggal.Stroke, [KendangBaliTunggal.Note])]
    -> Korvai.Realizations
make_kendang1 strokes = mempty
    { Korvai.kendang_bali_tunggal = check $
        KendangBaliTunggal.instrument strokes KendangBaliTunggal.defaults
    }

korvais :: CallStack.Stack => Solkattu.Tala -> Korvai.Realizations -> [Sequence]
    -> [Korvai]
korvais tala realizations = map (korvai tala realizations)

korvai :: Solkattu.Tala -> Korvai.Realizations -> Sequence -> Korvai.Korvai
korvai = Korvai.korvai

adi :: Matras -> Solkattu.Tala
adi = Solkattu.adi_tala

many :: (a -> IO ()) -> [a] -> IO ()
many f xs = sequence_ $ List.intersperse (putChar '\n') $ map put (zip [0..] xs)
    where put (i, x) = putStrLn ("---- " ++ show i) >> f x

realize, realizep :: Korvai.Korvai -> IO ()
realize = realize_ True
realizep = realize_ False

realize_ :: Bool -> Korvai.Korvai -> IO ()
realize_ realize_patterns korvai =
    Text.IO.putStrLn $ case Korvai.realize realize_patterns korvai of
        Left err -> "ERROR:\n" <> err
        Right notes -> Realize.format (Korvai.korvai_tala korvai) notes
