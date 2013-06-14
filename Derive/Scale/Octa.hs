-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.Scale.Octa where
import qualified Data.Map as Map
import qualified Data.Vector.Unboxed as Vector

import qualified Derive.Scale as Scale
import qualified Derive.Scale.Theory as Theory
import qualified Derive.Scale.TheoryFormat as TheoryFormat
import qualified Derive.Scale.TwelveScales as TwelveScales
import qualified Derive.Scale.Util as Util

import qualified Perform.Pitch as Pitch


scales :: [Scale.Scale]
scales =
    [ make_scale (Pitch.ScaleId "octa21") layout21 keys21 absolute_fmt
    , make_scale (Pitch.ScaleId "octa12") layout12 keys12 absolute_fmt
    , make_scale (Pitch.ScaleId "octa21-r") layout21 keys21
        (relative_fmt keys21)
    , make_scale (Pitch.ScaleId "octa12-r") layout12 keys12
        (relative_fmt keys12)
    ]
    where
    layout21 = Theory.layout [2, 1, 2, 1, 2, 1, 2, 1]
    layout12 = Theory.layout [1, 2, 1, 2, 1, 2, 1, 2]
    keys21 = all_keys layout21
    keys12 = all_keys layout12

absolute_fmt :: TheoryFormat.Format
absolute_fmt =
    TheoryFormat.make_absolute_format (TheoryFormat.make_pattern degrees)
        degrees TheoryFormat.ascii_accidentals
    where
    degrees = TheoryFormat.make_degrees ["a", "b", "c", "d", "e", "f", "g", "h"]

relative_fmt :: TwelveScales.Keys -> TheoryFormat.Format
relative_fmt keys =
    TheoryFormat.make_relative_format (TheoryFormat.make_pattern degrees)
        degrees TheoryFormat.ascii_accidentals parse_key default_tkey
        TheoryFormat.show_note_chromatic TheoryFormat.adjust_chromatic
    where
    degrees = TheoryFormat.make_degrees
        ["一", "二", "三", "四", "五", "六", "七", "八"]
    parse_key = TwelveScales.lookup_key default_tkey keys
    Just default_tkey = Map.lookup default_key keys

make_scale :: Pitch.ScaleId -> Theory.Layout -> TwelveScales.Keys
    -> TheoryFormat.Format -> Scale.Scale
make_scale scale_id layout keys fmt = Scale.Scale
    { Scale.scale_id = scale_id
    , Scale.scale_pattern = TheoryFormat.fmt_pattern fmt
    , Scale.scale_symbols = []
    , Scale.scale_transposers = Util.standard_transposers
    , Scale.scale_transpose = TwelveScales.transpose scale_map
    , Scale.scale_enharmonics = TwelveScales.enharmonics scale_map
    , Scale.scale_note_to_call = TwelveScales.note_to_call scale_map
    , Scale.scale_input_to_note = TwelveScales.input_to_note scale_map
    , Scale.scale_input_to_nn = Util.direct_input_to_nn
    , Scale.scale_call_doc = TwelveScales.call_doc Util.standard_transposers
        scale_map
        "Octatonic scales as true 8 note scales, using notes from a-h.\
        \ There are two variants: octa21 starts with a whole step, while\
        \ octa12 starts with a half-step."
    }
    where
    scale_map = TwelveScales.scale_map layout fmt keys default_tkey
    Just default_tkey = Map.lookup default_key keys

default_key :: Pitch.Key
default_key = Pitch.Key "a"

all_notes :: [Theory.Note]
all_notes = [Theory.Note pc accs | pc <- [0..7], accs <- [-1..1]]

make_keys :: Theory.Layout -> [Theory.Semi] -> [Theory.Key]
make_keys layout intervals =
    [Theory.key tonic "" intervals layout
        | tonic <- all_notes, abs (Theory.note_accidentals tonic) <= 1]

all_keys :: Theory.Layout -> TwelveScales.Keys
all_keys layout =
    Map.fromList $ zip (map (TheoryFormat.show_key absolute_fmt) keys) keys
    where
    keys = make_keys layout $ Vector.toList (Theory.layout_intervals layout)
