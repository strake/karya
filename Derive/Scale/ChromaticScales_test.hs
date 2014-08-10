-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.Scale.ChromaticScales_test where
import Util.Control
import Util.Test
import qualified Cmd.CmdTest as CmdTest
import qualified Derive.Scale as Scale
import qualified Derive.Scale.ChromaticScales as ChromaticScales
import qualified Derive.Scale.Twelve as Twelve

import qualified Perform.Pitch as Pitch


test_input_to_note = do
    let f smap key = either prettyt Pitch.note_text <$>
            ChromaticScales.input_to_note smap (Just (Pitch.Key key))
        abs = Twelve.absolute_scale_map
        rel = Twelve.relative_scale_map
        ascii (oct, pc, accs) =
            Pitch.Input Pitch.AsciiKbd (CmdTest.pitch oct pc accs) 0
    equal (map (f abs "c-maj" . ascii) [(5, 6, 0), (5, 6, 1), (5, 7, 0)])
        ["5b", "6c", "6c"]
    equal (map (f rel "d-min" . ascii) [(4, 2, 0), (4, 2, 1), (4, 3, 0)])
        ["4g", "4g#", "4m"]

test_transpose = do
    let f smap key_ trans steps =
            ChromaticScales.show_pitch (ChromaticScales.smap_layout smap)
                    (ChromaticScales.smap_fmt smap) key
                <=< ChromaticScales.transpose smap trans key steps
                <=< ChromaticScales.read_pitch (ChromaticScales.smap_fmt smap)
                    key
            where key = Just (Pitch.Key key_)
        rel = Twelve.relative_scale_map
        abs = Twelve.absolute_scale_map
    equal [f abs "f#-min" Scale.Diatonic n "4f#" | n <- [0..4]] $
        map Right ["4f#", "4g#", "4a", "4b", "5c#"]
    equal [f rel "f#-min" Scale.Diatonic n "4s" | n <- [0..4]] $
        map Right ["4s", "4r", "4g", "4m", "4p"]
    equal (f rel "f#-min" Scale.Diatonic 2 "4s") (Right "4g")
