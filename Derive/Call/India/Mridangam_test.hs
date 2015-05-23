-- Copyright 2015 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.Call.India.Mridangam_test where
import Util.Test
import qualified Ui.UiTest as UiTest
import qualified Derive.Derive as Derive
import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.Score as Score

import qualified Local.Instrument.Kontakt as Kontakt

import Global


test_pattern = do
    let run = DeriveTest.extract extract . derive_tracks ""
        extract e = (Score.event_start e, DeriveTest.e_attributes e)
    equal (run [(2, 5, "p1 ktkno")])
        ([(2, "+ki"), (3, "+ta"), (4, "+ki"), (5, "+nam"), (6, "+thom")], [])
    equal (run [(2, 3, "p1 k_D")])
        ([(2, "+ki"), (4, "+thom"), (4, "+din")], [])

    equal (run [(2, 4, "pr kt")])
        ([(2, "+ki"), (3, "+ta"), (4, "+ki"), (5, "+ta")], [])
    equal (run [(2, 3, "pr kt")])
        ([(2, "+ki"), (3, "+ta"), (4, "+ki")], [])
    equal (run [(2, 2, "Pr kt")])
        ([(2, "+ta"), (3, "+ki"), (4, "+ta")], [])

    equal (run [(2, 6, "pn kt 3")])
        ([(2, "+ki"), (3, "+ta"), (4, "+ki"), (5, "+ta"), (6, "+ki"),
            (7, "+ta")], [])

test_infer_pattern = do
    let run title = DeriveTest.extract extract . derive_tracks title
        extract e = (Score.event_start e, DeriveTest.e_attributes e)
        attrs = map ('+':) ["ki", "ta", "ki", "nam", "thom"]
    equal (run " | pattern = \"(pi 0 1)" [(1, 5, "p1 (pi 0 1)")])
        (zip [1, 2, 3, 4, 5] attrs, [])
    equal (run " | pattern = \"(pi 0 1)" [(1, 6, "p1")])
        (zip [1, 2, 4, 5, 6] attrs, [])
    equal (run " | pattern = \"(pi 0 1)" [(1, 7, "p1")])
        (zip [1, 3, 5, 6, 7] attrs, [])

derive_tracks2 :: String -> [UiTest.TrackSpec] -> Derive.Result
derive_tracks2 title notes = DeriveTest.derive_tracks_setup with_synth
    ("import india.mridangam" <> title) notes

derive_tracks :: String -> [UiTest.EventSpec] -> Derive.Result
derive_tracks title notes = DeriveTest.derive_tracks_setup with_synth
    ("import india.mridangam" <> title)
    [(">kontakt/mridangam", notes)]

with_synth :: DeriveTest.Setup
with_synth = DeriveTest.with_synth_descs mempty Kontakt.synth_descs
