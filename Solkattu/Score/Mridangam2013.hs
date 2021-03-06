-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE RecordWildCards #-}
-- | This is analogous to the solkattu scores, except for mridangam specific
-- scores.
module Solkattu.Score.Mridangam2013 where
import Prelude hiding ((.), repeat)

import Solkattu.MridangamGlobal


-- TODO use this as a template to fill in various themes
dinnagina_sequence :: Korvai
dinnagina_sequence = date 2013 9 11 $ ganesh $ sequenceT $ korvaiS1 adi $
    su $ mconcat $ map (sam.)
    [ sarvaA 16 ptheme
    , sarvaA 8 ptheme . sarvaA 8 ptheme

    -- start sarvalaghu with o k D D ...
    -- o k oktkoktkpktkt k oktkoktkoktk     x2
    , theme . ptheme . theme . ptheme
    , trin (od.__8) theme ptheme ptheme
    , theme . od.__8 . ptheme . od.__4 . eme . od.__4 . eme
    , theme . od.__8 . ptheme . od.__4 . eme . od.__2 . me . od.__2 . me
    -- the pattern is theme on sam and arudi, ptheme otherwise.
    , trin (od.__) (theme.me) (ptheme.me) (ptheme.me)
    , trin (od.__) theme (ptheme.me) (ptheme.me.me)
    , repeat 2 (theme.od.__4 . eme.od.__4 . eme . od.__4)
        . theme.od.__4 . eme.od.__ . me.od.__.me

    -- 1st variation
    -- 0   1   2   3   o3  . p   . o   . p   .
    -- o k oktkoktkoktkoktkokpktkpkoktkokpktkpk|o
    -- t k oktkokokou_kou_kkopu_kkoou_kkopu_kko|o
    -- t k oktkokokou_kkopu kkoou kkopu kkoou k|o
    -- 0   1   2   3   o3  . p   . o   . p   .
    -- , tri_ (o.__4) (ptheme . me . pme . ome . pme . k.o)
    , tri_ (o.__4) (theme . eme3b . pme3b . eme3b . pme3b)
    -- 2nd variation
    -- 0   1   2   3   p3  . o   . p   . o   .
    -- t k oktkokokou_kkopu kkoou kkopu kkoou k|o
    --   k oktkokokkk____pkk____okk____pkk__okk_
    , tri_ (o.__4) (theme . pme3b' . eme3b' . pme3b' . eme3b')
    ]
    where
    -- dhom ka dinnagina takataka talang ga
    theme = o.__.k.__.o.k.t.k.o.k.o.k.o.u.__.k
    -- TODO not quite right, this has to be ptheme when not on an sam or arudi
    ptheme = t `replaceStart` theme
    eme = rtakeM 8 theme
    me = rtakeM 4 theme

    eme3a = o.k.t.k.o.k
    pme3a = p.k.t.k.p.k

    eme3b = o.u.__.k.k.o
    pme3b = p.u.__.k.k.o

    eme3b' = k.o.o.u.__.k
    pme3b' = k.o.p.u.__.k

    -- themes:
    -- dhom ka dinnagina dinnagina dinnagina (tanagina)
    -- o_k_ oktk oktk oktk (pktk)
    -- dhom ka dinnagina dinnagina takataka
    -- o_k_ oktk oktk okok (pkpk)
    -- dhom ka dinnagina dhomkadhomka talang ga -- 2013 9 18
    -- o_k_ oktk okok ou_k
    -- dhom ka dinnagina dinnadinna dinnatat_ (drop next dhom) -- 2013 10 9
    -- o_k_ oktk okok okk__ (pkk__)
    -- dhom ka dinnagina dinnadinna dinnataka -- 2013 10 24
    -- o_k_ oktk okok okko
    --
    -- o_k_ookn ookn ookn (ppkn) -- 2013 10 29
    -- o_knookn o_kn ookn
    -- mix and match oktk, okok, ookn
    --
    -- ktnoktknokt kno -- 2013 11 5, progression different
    -- su: o t k n ktok

-- * sarvalaghu

t_17_02_13 :: Korvai
t_17_02_13 = date 2017 2 13 $ ganesh $ sarvalaghu $ korvaiS adi $ map (nadai 6)
    [ takitadin.kadin . takitadin.kadin . takitatin.katin
        . takitatin.k.takitatin.k
    , takitadin.kadin . __ . dropM 1 takitadin . kadin . takitatin.katin
        . __ . p.k.od.__ . p.k.od.__ . p.k.od
    ]
    where
    takitadin   = k.p.k.od.__
    takitatin   = k.p.k. d.__
    kadin = k.od.__.o&n.__.k.__
    katin = k. d.__.  n.__.k.__

din_nadin :: Korvai
din_nadin = sarvalaghu $ ganesh $ korvaiS (beats 4)
    [ od.__.on.od.l.od.on.l.od.l.on.od.l.od.on.l
    , su $ repeat 2 $ d.__.p.k.n.l.d.__.p.l.d.__.n.__.l.__
    , su $ repeat 2 $ d.__.p.k.n.l.d.l.p.l.d.l.n.l.p.l
    ]

nadin_ka :: Korvai
nadin_ka = sarvalaghu $ ganesh $ date 2017 5 15 $ korvaiS1 (beats 4) $
    on.od.__.k.(n.d.__.k).(n.d.__.k).o.od.__.k
    -- 4 nd to switch to kandam

nadindin :: Korvai
nadindin = sarvalaghu $ korvaiS adi $ map sd
    [ template $ lh & rh
    , template $ su (on.on) . od.od.on
    , template $ su (su (k.t.o.k) . o.k) . o . k
    -- TODO if I have a notation for alternatives I could put it in here
    -- melkalam
    , su $ inter l $ repeat 4 rh & (repeat 8 o . o.__4 . __ . repeat 3 o)
    -- TODO For the others, I should have a way to intersperse at a certain
    -- speed, or maybe mix together two sequences.  Or maybe I can infer 'l'
    -- for melkalam?
    ]
    where
    template var = (lh & rh) . var . (rh . rh) & (o.__4 . __ . repeat 3 o)
    rh = n.d.d.n
    lh = o.o.o.o

-- | Some patterns are more naturally expressed with negative orientation.
-- I don't have support for that, and I don't even know how I would, but here's
-- a simple motivating example.
nadindin_negative :: Korvai
nadindin_negative = sarvalaghu $ korvaiS adi $ map sd
    [ __ . lh & rh . lh  & rh  . rh . lh & rh
    , __ . lh & rh . lh1 & rh1 . rh . lh & rh
    ]
    where
    -- For this to work right, I need the the duration of each note to be
    -- negative.
    rh1 = su (n.d) . d.n -- should be: su n . d.d.n
    lh1 = su (o.o) . o.o -- should be: su o . o.o.o
    rh = d.d.n.n
    lh = o.o.o.o

namita_dimita :: Korvai
namita_dimita = sarvalaghu $ korvaiS1 adi $
    __ . (lh & rh) . (lh & rh) . rh . (lh & rh)
    where
    rh = l.d.d.l.d.d.l.n
    lh = __3.o.__3.o.__.o

-- ** sarvalaghu fills

namita_dimita_dimi :: [Sequence]
namita_dimita_dimi =
    [ o&n.__.k.t.p.k.p.k.t.k.n.o.o.k.k.__
    , k.t.k.t . k.t.k.n.kt.p.k . o.t.k.n.kt.p.k . o.n.kt.p.k
    -- goes past sam: previous . o.t.k.o&n.kt.p.k
    ]
    where kt = su (k.t)

janahan_exercise :: Korvai
janahan_exercise = exercise $ janahan $ korvaiS1 adi $
    o&d.__4 . repeat 7 (n.p.k.t.p.k.t.p) . k.t.p.k

nakanadin :: Korvai
nakanadin = sarvalaghu $ korvaiS1 (beats 2) $ su $
    d.__3.y.n.y.d.__3.y.d.y.n.y.n.y


-- * farans

farans :: Korvai
farans = faran $ korvaiS adi $ map su $ concat
    [ map (make (p.n.p.k) (p.n.p.k . t.k))
        [ k.t.k.n.p.k.t.k
        , o.o.k.n.p.k.t.k
        , o.o.n.n.p.k.t.k
        , o.t.k.n.p.k.t.k
        , od.__.od.n.p.k.t.k
        , o.d.o.n.p.k.t.k
        , o.k.o.n.p.k.t.k
        , o&t.k.o.n.p.k.t.k
        , p.u.__.n.p.k.t.k
        , o.u.__.n.p.k.t.k
        ]
    , map (make (o.u.__.k) (o.u.__.k . t.k))
        [ o.u.__.k.k.o.o.k -- 11
        , o.u.p.k.k.o.o.k
        , o.k.o.u.__.k.t.k
        , o.k.o.u.p.k.t.k -- 14
        ]
    , map (make (o.__.k.__) (o.k.p.k . t.k))
        [ o.k.o.o.k.o.o.k
        , o.__.k.o.k.o.o&t.k
        , o.o.k.o.k.o.o&t.k
        , o.__.k.t.k.o.o&t.k
        , o.o.k.t.k.o.o&t.k
        , k.__.k.t.k.o.o&t.k
        , k.p.k.t.k.o.o&t.k
        , n.k.p.p.k.o.o.k
        ]
    , [ make (o.o.k.t) (p.k.p.k . t.k) (p.k.o.o.k.t.p.k)
      , make (n.o.o&k.__) (o&k.__.u.__ . p.k) (n.o.o&k.__.u.__.p.k)
      ]
    ]
    where
    make fill1 fill2 pattern =
        long . long
        . group pattern . group pattern . long
        . repeat 2 short . fill1 . long
        . repeat 3 short . fill2 . nakatiku
        where
        long = group pattern . nakatiku
        short = takeM 6 pattern

-- * fragments

eddupu6 :: Korvai
eddupu6 = korvaiS (beats 3)
    [ repeat 2 (k.__.p.__.k.__)
    , repeat 2 (od.__.p.k.n.o)
    , repeat 3 (k.o.o.k)
    , repeat 2 (o.o.t.__.k.__)
    , k.p.k.__.t.__.k.t.__.k.n.o
    , __.__.u.__3.k.o.o&t.k.n.o.k
    , su $ repeat 2 nang_kita
    ]

eddupu10 :: Korvai
eddupu10 = korvaiS (beats 5)
    [ repeat 2 $ u.__3.k.o.o&t.k.n.o.k
    , __.__ . repeat 3 p6
    ]

nang_kita :: Sequence
nang_kita = o&n . __ . p.k.nakatiku
