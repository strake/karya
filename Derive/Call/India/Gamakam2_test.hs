-- Copyright 2014 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.Call.India.Gamakam2_test where
import Util.Control
import Util.Test
import qualified Ui.UiTest as UiTest
import qualified Derive.DeriveTest as DeriveTest
import qualified Perform.Pitch as Pitch
import qualified Perform.Signal as Signal
import Types


test_sequence = do
    let run = run_note_track ""
    strings_like (snd (run [(0, 8, "!; no-call; -- 4c")]))
        ["generator not found"]

    -- Implicit hold.
    equal (run [(0, 8, "! -- 4c")]) ([[(0, 60), (8, 60)]], [])
    equal (run [(0, 8, "!;; -- 4c")]) ([[(0, 60), (8, 60)]], [])
    -- Implicit set pitch if you don't supply a begin call.
    equal (run [(0, 1, "4c"), (1, 1, "! -- 4d")])
        ([[(0, 60)], [(1, 62), (2, 62)]], [])

    -- From call.
    equal (run [(0, 1, "4c"), (1, 4, "! -^ 2 -- 4d")])
        ([[(0, 60)], [(1, 60), (2, 61), (3, 62), (5, 62)]], [])
    equal (run [(0, 4, "! p 1 1 -- 4c")])
        ([[(0, 61), (1, 60), (4, 60)]], [])

    -- To call.
    equal (run [(0, 4, "!; - ; p 2 2 -- 4c")])
        ([[(0, 60), (2, 60), (3, 61), (4, 62)]], [])
    equal (run [(0, 4, "!;; p 2 2 -- 4c")])
        ([[(0, 60), (2, 60), (3, 61), (4, 62)]], [])

    -- Enough room.
    equal (run [(0, 8, "!;; p 2 2 -- 4c")])
        ([[(0, 60), (6, 60), (7, 61), (8, 62)]], [])
    equal (run [(0, 2, "!;; p 2 2 -- 4c")])
        ([[(0, 60), (1, 61), (2, 62)]], [])
    -- Not enough room.
    equal (run [(0, 1, "!;; p 2 2 -- 4c")])
        ([[(0, 60), (1, 62)]], [])

    -- Medium is divided evenly.
    equal (run [(0, 8, "!; - 1; - 0; -- 4c")])
        ([[(0, 61), (4, 60), (8, 60)]], [])

    -- Begin, middle, end.
    equal (run [(0, 8, "! p 1 1;; p 1 1 -- 4c")])
        ([[(0, 61), (1, 60), (7, 60), (8, 61)]], [])
    -- Middle divided equally between 59 and 60.
    equal (run [(0, 8, "! p 1 1; - -1; - 0; p 1 1 -- 4c")])
        ([[(0, 61), (1, 59), (4, 60), (7, 60), (8, 61)]], [])

test_fade = do
    let run = run_note_track_dyn ""
    equal (run [(0, 4, "!;; > 2 -- 4c")])
        ([( [(0, 60), (4, 60)]
          , [(0, 1), (2, 1), (3, 0.5), (4, 1)]
          )], [])

test_jaru = do
    let run = run_note_track "| jaru-time=1 | jaru-transition=1"
    equal (run [(0, 4, "! j 1 -1 -- 4c")])
        ([[(0, 62), (1, 59), (4, 59)]], [])
    equal (run [(0, 2, "! j 1 -1 1 -- 4c")])
        ([[(0, 62), (1, 59), (2, 62)]], [])
    equal (run [(0, 1, "! j 1 -1 1 -- 4c")])
        ([[(0, 62), (0.5, 59), (1, 62)]], [])

test_kampita = do
    let run = run_note_track "| kam-transition=0 | kam-speed=1"
    equal (run [(0, 2.5, "!; k 1; -- 4c")])
        ([[(0, 60), (1, 61), (2, 60)]], [])
    equal (run [(0, 2.5, "!; k^ 1; -- 4c")])
        ([[(0, 60), (1, 61)]], [])
    equal (run [(0, 2.5, "!; k_ 1; -- 4c")])
        ([[(0, 60), (1, 61), (2, 60)]], [])
    -- Starts from the previous pitch.
    equal (run [(0, 4, "!; hold -1; k 1; -- 4c")])
        ([[(0, 59), (2, 59), (3, 60), (4, 59)]], [])

    -- Adjust.
    equal (run [(0, 2.5, "kam-adjust=stretch | !; k^ 1; -- 4c")])
        ([[(0, 60), (2.5, 61)]], [])

test_nkampita = do
    let run = run_note_track "| nkam-transition=0"
    strings_like (snd (run [(0, 2, "! ; nk 0; -- 4c")]))
        ["cycles: expected Num (>0)"]
    equal (run [(0, 2, "!; nk 1; -- 4c")])
        ([[(0, 60), (1, 61), (2, 60)]], [])
    equal (run [(0, 2, "!; nk_ 1; -- 4c")])
        ([[(0, 60), (1, 61), (2, 60)]], [])
    equal (run [(0, 2, "!; nk 2; -- 4c")])
        ([[(0, 60), (0.5, 61), (1, 60), (1.5, 61), (2, 60)]], [])
    equal (run [(0, 2, "!; nk^ 1; -- 4c")])
        ([[(0, 60), (2, 61)]], [])
    equal (run [(0, 2, "!; nk_ 1 -1; -- 4c")])
        ([[(0, 60), (2, 59)]], [])
    equal (run [(0, 4, "nkam-transition=2 | !; nk^ 1; -- 4c")])
        ([[(0, 60), (3, 60.5), (4, 61)]], [])

run_note_track_dyn :: String -> [UiTest.EventSpec]
    -> ([([(RealTime, Pitch.NoteNumber)], [(RealTime, Signal.Y)])], [String])
run_note_track_dyn = run_ (\e -> (DeriveTest.e_nns e, DeriveTest.e_dyn e))

run_note_track :: String -> [UiTest.EventSpec]
    -> ([[(RealTime, Pitch.NoteNumber)]], [String])
run_note_track = run_ DeriveTest.e_nns

run_ extract transform = DeriveTest.extract extract
    . DeriveTest.derive_tracks ("import india.gamakam2 " <> transform)
    . UiTest.note_track