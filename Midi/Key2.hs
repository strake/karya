-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Symbolic names for all the MIDI keys, with middle C at C3, since lots of
-- synths do that.
module Midi.Key2 where
import qualified Midi.Midi as Midi

c_2 : cs_2 : d_2 : ds_2 : e_2 : f_2 : fs_2 : g_2 : gs_2 : a_2 : as_2 : b_2
    : c_1 : cs_1 : d_1 : ds_1 : e_1 : f_1 : fs_1 : g_1 : gs_1 : a_1 : as_1 : b_1
    : c0 : cs0 : d0 : ds0 : e0 : f0 : fs0 : g0 : gs0 : a0 : as0 : b0
    : c1 : cs1 : d1 : ds1 : e1 : f1 : fs1 : g1 : gs1 : a1 : as1 : b1
    : c2 : cs2 : d2 : ds2 : e2 : f2 : fs2 : g2 : gs2 : a2 : as2 : b2
    : c3 : cs3 : d3 : ds3 : e3 : f3 : fs3 : g3 : gs3 : a3 : as3 : b3
    : c4 : cs4 : d4 : ds4 : e4 : f4 : fs4 : g4 : gs4 : a4 : as4 : b4
    : c5 : cs5 : d5 : ds5 : e5 : f5 : fs5 : g5 : gs5 : a5 : as5 : b5
    : c6 : cs6 : d6 : ds6 : e6 : f6 : fs6 : g6 : gs6 : a6 : as6 : b6
    : c7 : cs7 : d7 : ds7 : e7 : f7 : fs7 : g7 : gs7 : a7 : as7 : b7
    : c8 : cs8 : d8 : ds8 : e8 : f8 : fs8 : g8
    : _ = map Midi.Key [0..] :: [Midi.Key]
