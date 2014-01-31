-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.Scale.Wayang_test where
import qualified Data.List as List

import Util.Control
import qualified Util.Seq as Seq
import Util.Test

import qualified Ui.UiTest as UiTest
import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.Scale as Scale
import qualified Derive.Scale.Wayang as Wayang
import qualified Derive.Score as Score

import qualified Perform.Pitch as Pitch


test_read = do
    let f scale pitch = read_scale (get_scale scale) pitch
    -- The same pitch also winds up with the same Pitch and same frequency.
    equal (f "wayang" "5i") (Right "5-0")
    equal (f "wayang-p" "i^") (Right "5-0")
    equal (f "wayang-k" "i-") (Right "5-0")
    let run scale pitch = DeriveTest.extract Score.initial_nn $
            DeriveTest.derive_tracks $ scale_track scale [pitch]
    equal (run "wayang" "5i") (run "wayang-p" "i^")
    equal (run "wayang" "5i") (run "wayang-k" "i-")

get_scale :: Text -> Scale.Scale
get_scale scale_id = fromMaybe (error $ "no scale: " ++ show scale_id) $
    List.find ((== Pitch.ScaleId scale_id) . Scale.scale_id) Wayang.scales

read_scale :: Scale.Scale -> Pitch.Note -> Either String String
read_scale scale note = either (Left . pretty) (Right . pretty) $
    Scale.scale_read scale Nothing note

scale_track :: String -> [String] -> [UiTest.TrackSpec]
scale_track scale_id pitches =
    [ (">", [(n, 1, "") | n <- map fst events])
    , ('*' : scale_id, [(n, 0, p) | (n, p) <- events])
    ]
    where events = zip (Seq.range_ 0 1) pitches
