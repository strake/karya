-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.Call.Grace_test where
import qualified Data.Map as Map

import Util.Control
import Util.Test
import qualified Ui.UiTest as UiTest
import qualified Derive.Call.Articulation as Articulation
import qualified Derive.Call.CallTest as CallTest
import qualified Derive.Call.Grace as Grace
import qualified Derive.Derive as Derive
import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.Score as Score

import qualified Perform.Lilypond.LilypondTest as LilypondTest


test_mordent = do
    let run = DeriveTest.extract DeriveTest.e_pitch . run_note
    equal (run (1, 1, "`mordent`")) (["4c", "4d", "4c"], [])
    equal (run (1, 1, "`rmordent`")) (["4c", "3b", "4c"], [])

run_note :: UiTest.EventSpec -> Derive.Result
run_note note = DeriveTest.derive_tracks [(">", [note]), ("*", [(0, 0, "4c")])]

test_grace = do
    let run extract = DeriveTest.extract extract . DeriveTest.derive_tracks
        run_n = run DeriveTest.e_note
        tracks notes = [(">", notes), ("*", [(0, 0, "4c")])]
        prefix = "legato-detach = 0 | %legato-overlap = 0 | grace-dur = 1 |"

    let legato_tracks note = tracks [(2, 1,
            "legato-detach = .25 | grace-dur = 1 | %legato-overlap = .5 | "
                <> note)]
        dur = 1
        overlap = 0.5
        detach = 0.25
        e_dyn e = (DeriveTest.e_note e, Score.initial_dynamic e)
    equal (run e_dyn $ legato_tracks "grace-dyn = .5 | g (4a) (4b)")
        ( [ ((2-dur*2, dur+overlap, "4a"), 0.5)
          , ((2-dur, dur+overlap, "4b"), 0.5)
          , ((2, 0.75, "4c"), 1)
          ]
        , []
        )

    -- Ensure the grace-dyn default is picked up too.
    equal (run e_dyn $ legato_tracks "grace-dyn = 1 | g (4b)")
        ([((2-dur, dur+overlap, "4b"), 1), ((2, 1-detach, "4c"), 1)], [])

    -- grace-dur defaults to RealTime, but can be ScoreTime.
    let tempo_tracks note = ("tempo", [(0, 0, "2")])
            : tracks [(4, 2, "%legato-overlap = 0 | " <> note)]
    equal (run_n $ tempo_tracks "grace-dur = 1 | g (4b)")
        ([(1, 1, "4b"), (2, 1, "4c")], [])
    equal (run_n $ tempo_tracks "grace-dur = 1t | g (4b)")
        ([(1.5, 0.5, "4b"), (2, 1, "4c")], [])

    -- grace-place
    let place_tracks note = tracks [(2, 2, prefix <> note)]
    equal (run_n $ place_tracks "%grace-place = 1 | g (4b)")
        ([(2, 1, "4b"), (3, 1, "4c")], [])
    -- Grace notes shorten if the note can't accomodate them all.
    equal (run_n $ place_tracks "%grace-place = 1 | g (4a) (4b) (4d)")
        ( [ (2, 0.5, "4a"), (2.5, 0.5, "4b")
          , (3, 0.5, "4d"), (3.5, 0.5, "4c")
          ]
        , []
        )
    equal (run_n $ place_tracks "%grace-place = .5 | g (4b)")
        ([(1.5, 1, "4b"), (2.5, 1.5, "4c")], [])

    -- Ensure grace works with attr legato.
    let run_a = DeriveTest.extract DeriveTest.e_attributes
            . DeriveTest.derive_tracks_with with
        with = CallTest.with_note_generator "(" Articulation.c_attr_legato
    equal (run_a $ tracks [(0, 1, "g (4a) (4b)")])
        (["+legato", "+legato", "+legato"], [])

test_grace_ly = do
    let run = LilypondTest.derive_measures ["acciaccatura"]
    equal (run
        [ (">", [(0, 2, "g (4a) (4b)"), (2, 2, "g (3a)")])
        , ("*", [(0, 0, "4c"), (2, 0, "4b")])
        ])
        (Right "\\acciaccatura { a'8[ b'8] } c'2 \\acciaccatura { a8 } b'2", [])
    equal (run
        [ ("> | v = 1", [(0, 4, "")])
        , ("*", [(0, 0, "3c")])
        , ("> | v = 2", [(0, 4, "g (3e)")])
        , ("*", [(0, 0, "3d")])
        ])
        (Right "<< { VoiceOne: c1 } { VoiceTwo: \\acciaccatura { e8 } d1 } >>",
            [])

test_grace_attr = do
    let run note = DeriveTest.extract extract $
            DeriveTest.derive_tracks_with with_call
                [ ("> | %legato-overlap = .5 | grace-dur = 1", [note])
                , ("*", [(0, 0, "4c")])
                ]
        extract e = (DeriveTest.e_start_dur e, DeriveTest.e_pitch e,
            DeriveTest.e_attributes e)
        with_call = CallTest.with_note_generator "g" (Grace.c_grace_attr graces)
    -- Attrs when it can.
    equal (run (0, 1, "g (3bb)"))
        ([((-1, 2), "4c", "+up+whole")], [])
    equal (run (0, 1, "g 1c"))
        ([((-1, 2), "4c", "+down+half")], [])
    -- Notes when it can't.
    equal (run (0, 1, "g (4a)"))
        ([((-1, 1.5), "4a", "+"), ((0, 1), "4c", "+")], [])

graces :: Map.Map Int Score.Attributes
graces = Map.fromList
    [ (-1, Score.attrs ["half", "down"])
    , (2, Score.attrs ["whole", "up"])
    ]


test_grace_p = do
    let run = CallTest.run_pitch
    equal (run [(0, "grace-dur = 2 | g (4c) -2 -1"), (10, "--")])
        [(0, 57), (2, 59), (4, 60)]
    equal (run [(0, "grace-dur = 2 | g (4c) -2c -1"), (3, "--")])
        [(0, 58), (1, 59), (2, 60)]


test_mordent_p = do
    let run = CallTest.run_pitch
    equal (run [(0, "grace-dur = 2 | `mordent` (4c)")])
        [(0, 60), (2, 62), (4, 60)]
