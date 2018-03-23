-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | A version of a just intonation diatonic scale that is tuned based on
-- a pitch signal.
module Derive.Scale.Just where
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Vector as Vector

import qualified Util.Doc as Doc
import qualified Derive.BaseTypes as BaseTypes
import qualified Derive.Env as Env
import qualified Derive.Scale as Scale
import qualified Derive.Scale.ChromaticScales as ChromaticScales
import qualified Derive.Scale.JustScales as JustScales
import qualified Derive.Scale.Scales as Scales
import qualified Derive.Scale.Theory as Theory
import qualified Derive.Scale.TheoryFormat as TheoryFormat
import qualified Derive.ShowVal as ShowVal

import qualified Perform.Pitch as Pitch
import Global


scales :: [Scale.Definition]
scales = simple_scales ++ make_scales

simple_scales :: [Scale.Definition]
simple_scales = map Scale.Simple
    [ Scales.add_doc "7-note just scale." $
        JustScales.make_scale "just" (scale_map TheoryFormat.absolute_c)
            doc doc_fields
    , Scales.add_doc "7-note just scale." $
        JustScales.make_scale "just-r"
            (scale_map (TheoryFormat.sargam relative_fmt)) doc doc_fields
    ]
    where
    relative_fmt = JustScales.make_relative_fmt keys default_key

make_scales :: [Scale.Definition]
make_scales =
    [ scale_make_just "make-just7" TheoryFormat.absolute_c
    , scale_make_just "make-just7-r" (TheoryFormat.sargam relative_fmt)
    ]
    where
    relative_fmt = JustScales.make_relative_fmt mempty default_key
    default_key = JustScales.Key
        { key_tonic = 0
        , key_ratios = Map.fromList []
        }

doc :: Doc.Doc
doc =
    "7-note scales tuned in just intonation.\
    \\nThey are fundamentally 7 note scales because they use a A-G or SRGMPDN.\
    \ While they support sharps and flats and have a piano-style layout,\
    \ accidentals are implemented as simple ratio offsets from base pitch.\
    \ Extending to more flexible notions of just intonation would require\
    \ generalizing the input mapping and pitch notation.\
    \\nKeys look like `c-maj`, where `c` is the tonic and `maj` selects\
    \ the ratios to use. For absolute notation, the tonic determines where\
    \ the scale starts, while for relative notation, the tonic determines\
    \ only which MIDI key maps to the first scale degree. So for the ASCII kbd\
    \ where the input is also relative, the tonic is irrelevant."

doc_fields :: [(Doc.Doc, Doc.Doc)]
doc_fields =
    [ (Doc.literal name,
        Doc.Doc $ JustScales.show_ratios (JustScales.key_ratios key))
    | (name, key) <- ChromaticScales.group_tonic_mode (Map.toList keys)
    ]

scale_map :: TheoryFormat.Format -> JustScales.ScaleMap
scale_map = JustScales.scale_map keys default_key (Just default_tuning)

default_key :: JustScales.Key
Just default_key = Map.lookup (Pitch.Key "c-maj") keys

keys :: Map Pitch.Key JustScales.Key
keys = JustScales.make_keys TheoryFormat.absolute_c_degrees key_ratios

key_ratios :: [(Text, [(JustScales.Tuning, JustScales.Ratios)])]
key_ratios =
    [ (name, map (second (select is)) (Map.toList tunings))
    | (name, is) <- intervals
    ]
    where
    intervals = map (second (take 7)) $ zip names $ List.tails $
        cycle Theory.piano_intervals
    -- The names are the same as in Twelve.
    names = ["maj", "dorian", "phrygian", "lydian", "mixolydian", "min",
        "locrian"]

select :: [Int] -> Vector.Vector a -> Vector.Vector a
select intervals v =
    Vector.unfoldrN (length intervals) make (scanl (+) 0 intervals)
    where
    make (i:is) = Just (v Vector.! i, is)
    make [] = Nothing

tunings :: Map JustScales.Tuning JustScales.Ratios
tunings = Map.fromList $ map (second Vector.fromList)
    -- 5-limit would be more natural than limit-5, but I'd need quotes then.
    [ ("limit-5",
        [1, 16/15, 9/8, 6/5, 5/4, 4/3, 45/32, 3/2, 8/5, 5/3, 9/5, 15/8])
    , ("limit-7",
        [1, 15/14, 8/7, 6/5, 5/4, 4/3, 7/5, 3/2, 8/5, 5/3, 7/4, 15/8])
    ]
    -- 11+ limit adds intervals which get increasingly far from the 7 note
    -- framework, so I'd need some other way to name them.

default_tuning :: JustScales.Tuning
default_tuning = "limit-5"

{-
    c   db     d    eb   e    f    f#     g    ab   a    bb   b
    [1, 16/15, 9/8, 6/5, 5/4, 4/3, 45/32, 3/2, 8/5, 5/3, 9/5, 15/8]

    Ptolemy's intense diatonic scale.
    I, IV, and V are in-tune major triads of 4:5:6.
    But ii and vii dim not very ideal.
    [1,        9/8,      5/4, 4/3,        3/2,      5/3,      15/8]

    i, iv, and v are in-tune minor triads of 10:12:15.
    But ii dim and VII are out.
    [1,        9/8, 6/5,      4/3,        3/2, 8/5,      9/5]
-}


-- * make just

-- | Make a 7 note just scale with custom ratios or intervals.
scale_make_just :: Pitch.ScaleId -> TheoryFormat.Format -> Scale.Definition
scale_make_just scale_id fmt =
    Scale.Make scale_id (TheoryFormat.fmt_pattern fmt, call_doc)
        (make_just scale_id fmt)
    where
    call_doc = Scales.annotate_call_doc Scales.standard_transposers
        doc [] JustScales.default_call_doc
    doc = "Uses " <> ShowVal.doc just_ratios <> " to make a custom scale.\
        \The ratios should have exactly 6 elements (the initial 1/1 is\
        \ implicit)."

just_ratios :: Env.Key
just_ratios = "just-ratios"

make_just :: Pitch.ScaleId -> TheoryFormat.Format
    -> Env.Environ -> Scale.LookupScale
    -> Either BaseTypes.PitchError Scale.Scale
make_just scale_id fmt env _ = do
    ratios <- parse_ratios env
    let default_key = JustScales.Key
            { key_tonic = 0
            , key_ratios = Map.fromList [("", ratios)]
            }
    let smap = JustScales.scale_map Map.empty default_key Nothing fmt
    return $ JustScales.make_scale scale_id smap "doc unused" []

parse_ratios :: Env.Environ -> Either BaseTypes.PitchError JustScales.Ratios
parse_ratios = Scales.read_environ_ parse Nothing just_ratios
    where
    parse ratios
        | Vector.length v == 7 = Right v
        | otherwise = Left $ Just "length should be exactly 6"
        where v = Vector.fromList (1 : ratios)
