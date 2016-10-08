-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{- | Saih gender wayang.

    I use ding deng dong dung dang.  I don't know if this is ever actually used
    for gender, but the notation is compact and I don't think there are any
    other conventions.

    @
    3o  3e  3u  3a  4i  4o  4e  4u  4a  5i  5o  5e  5u  5a  6i
    pemade -------------------------------
                        kantilan -----------------------------
    @
-}
module Derive.Scale.Wayang where
import qualified Data.Map as Map
import qualified Data.Vector as Vector

import qualified Midi.Key2 as Key2
import qualified Midi.Midi as Midi
import qualified Derive.Scale as Scale
import qualified Derive.Scale.BaliScales as BaliScales
import qualified Derive.Scale.ChromaticScales as ChromaticScales
import qualified Derive.Scale.Scales as Scales
import qualified Derive.Scale.Theory as Theory
import qualified Derive.ShowVal as ShowVal

import qualified Perform.Midi.Patch as Patch
import qualified Perform.Pitch as Pitch
import Global


scales :: [Scale.Make]
scales = map (Scale.Simple . Scales.add_doc "Saih gender wayang.")
    [ BaliScales.make_scale scale_id complete_scale
    , Scales.add_doc
        "Pemade scale. This can be used to give the the same score to both\
            \ pemade and kantilan." $
        BaliScales.make_scale "wayang-pemade" pemade
    , Scales.add_doc
        "Kantilan scale. This can be used to give the the same score to both\
            \ pemade and kantilan." $
        BaliScales.make_scale "wayang-kantilan" kantilan
    ]

complete_scale :: BaliScales.ScaleMap
complete_scale =
    BaliScales.scale_map layout BaliScales.ioeua_absolute base_oct all_keys
        default_key saihs default_saih Nothing

pemade :: BaliScales.ScaleMap
pemade = inst_scale_map 4 pemade_low pemade_high

kantilan :: BaliScales.ScaleMap
kantilan = inst_scale_map 5 kantilan_low kantilan_high

inst_scale_map :: Pitch.Octave -> Pitch.Pitch -> Pitch.Pitch
    -> BaliScales.ScaleMap
inst_scale_map =
    BaliScales.instrument_scale_map
        BaliScales.ioeua BaliScales.arrow_octaves
        layout all_keys default_key saihs default_saih base_oct

-- | Start octave for the extended scale.
base_oct :: Pitch.Octave
base_oct = 1

pemade_low, pemade_high :: Pitch.Pitch
(pemade_low, pemade_high) = (Pitch.pitch 3 O, Pitch.pitch 5 I)

kantilan_low, kantilan_high :: Pitch.Pitch
(kantilan_low, kantilan_high) = (Pitch.pitch 4 O, Pitch.pitch 6 I)

scale_id :: Pitch.ScaleId
scale_id = "wayang"

layout :: Theory.Layout
layout = Theory.layout [1, 1, 1, 1, 1]

all_keys :: ChromaticScales.Keys
all_keys = mempty

default_key :: Theory.Key
default_key = Theory.key (Pitch.Degree 0 0) "default" [1, 1, 1, 1, 1] layout

-- * saihs

data Pitch = I | O | E | U | A deriving (Eq, Enum, Show)

default_saih :: Text
default_saih = "sawan"

saihs :: Map.Map Text BaliScales.Saih
saihs = Map.fromList
    [ (default_saih, saih_sawan)
    ]

saih_sawan :: BaliScales.Saih
saih_sawan = BaliScales.saih extend
    "Tuning from my gender wayang, made in Sawan, Singaraja."
    [ (53.00,   52.30) -- 3o, pemade begin
    , (55.15,   54.55)
    , (57.73,   57.35)
    , (60.40,   59.85)

    , (62.95,   62.50) -- 4i, pemade middle
    , (64.70,   64.45) -- 4o, kantilan begin
    , (67.57,   67.26)
    , (69.45,   69.25)
    , (72.10,   71.81)

    , (74.83,   74.63) -- 5i, pemade end, kantilan middle
    , (76.85,   76.73)
    , (79.48,   79.35)
    , (81.63,   81.51)
    , (84.12,   84.00)
    , (86.88,   86.78) -- 6i, kantilan end
    ]

-- | Extend down two octaves so that I start at 1i, and up two octaves to 8i.
--
-- pemade starts at 3o - 4i - 5i, kanti is 4o - 5i - 6i
extend :: [Pitch.NoteNumber] -> [Pitch.NoteNumber]
extend = BaliScales.extend_scale 5 (Pitch.pitch 1 I) (Pitch.pitch 8 I)
    pemade_low

undo_extend :: [a] -> [a]
undo_extend = take 15 . drop (1 + 5 + 5)
    -- take (kantilan_high - kantilan_low) . drop (pemade_low - 1 I)

-- * instrument integration

instrument_scale :: Bool -> BaliScales.Saih -> BaliScales.Tuning -> Patch.Scale
instrument_scale extended saih tuning =
    Patch.make_scale ("wayang " <> ShowVal.show_val tuning) $
        zip (midi_keys extended)
            ((if extended then id else undo_extend) (Vector.toList nns))
    where
    nns = case tuning of
        BaliScales.Umbang -> BaliScales.saih_umbang saih
        BaliScales.Isep -> BaliScales.saih_isep saih

-- | If extended is True, emit from i1 on up.  Otherwise, give pemade to
-- kantilan range.
midi_keys :: Bool -> [Midi.Key]
midi_keys extended = trim $ concatMap keys [base_oct + 1 ..]
    -- base_oct + 1 because MIDI starts at octave -1
    where
    trim
        | extended = take (7*5 + 1)
        | otherwise = take (3*5) . drop (1 + 3*5)
    keys oct = map (Midi.to_key (oct * 12) +) -- i o e u a
        [Key2.e_2, Key2.f_2, Key2.a_2, Key2.b_2, Key2.c_1]
