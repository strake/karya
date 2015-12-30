-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt
module Derive.Call.Bali.Reyong_test where
import qualified Util.Seq as Seq
import Util.Test
import qualified Ui.UiTest as UiTest
import qualified Derive.Call.Bali.Gangsa_test as Gangsa_test
import qualified Derive.Call.Bali.Reyong as Reyong
import Derive.Call.Bali.Reyong (Hand(..))
import qualified Derive.Derive as Derive
import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.Env as Env
import qualified Derive.EnvKey as EnvKey
import qualified Derive.Score as Score

import qualified Perform.Pitch as Pitch
import Global
import Types


title :: String
title = "import bali.reyong | scale=legong | cancel-kotekan 5"

title_with_damp :: Double -> String
title_with_damp dur = title <> " | infer-damp >i1 " <> show dur
    <> " | inst = >i1"

test_kilitan = do
    let run = e_voice 1 ex . DeriveTest.derive_tracks title . UiTest.note_track
        ex e = (Score.event_start e, DeriveTest.e_pitch e)
    equal (run [(0, 0, "X --"), (1, 0, "O --"), (2, 0, "+ --")])
        (Just [(0, "3u"), (1, "3e"), (1, "3a"), (2, "3e"), (2, "3a")], [])
    equal (run [(0, 4, ">kilit -- 3u"), (4, 4, "kilit -- 3u")])
        (Just
            [ (1, "3u"), (2, "3u"), (3, "3a"), (4, "3u")
            , (5, "3a"), (6, "3u"), (7, "3a"), (8, "3u")
            ], [])

test_kotekan_regular = do
    let run voice = first (lookup voice) . e_pattern 0
            . DeriveTest.derive_tracks title . UiTest.note_track
    equal (run 1 [(0, 8, "k k-12-1-21 -- 4i")]) (Just "ueu-eue-u", [])
    equal (run 2 [(0, 8, "k k-12-1-21 -- 4i")]) (Just "i-io-i-oi", [])
    equal (run 1 [(0, 8, "k// -- 4e")]) (Just "e-eu-eu-e", [])
    equal (run 2 [(0, 8, "k// -- 4e")]) (Just "-o-io-io-", [])

    -- Cancelling favors the end note.
    equal (run 2 [(0, 8, "k k-12-1-21 -- 4i"), (8, 8, "k// -- 4e")])
        (Just "i-io-i-oio-io-io-", [])
    equal (run 3 [(0, 8, "k k-12-1-21 -- 4i"), (8, 8, "k// -- 4e")])
        (Just "ueu-eue-u-eu-eu-e", [])

test_cancel_kotekan = do
    let run voice = DeriveTest.extract DeriveTest.e_note
            . DeriveTest.filter_events_range 7 9
            . DeriveTest.filter_events ((==voice) . event_voice)
            . DeriveTest.derive_tracks title . UiTest.note_track
    equal (run 2 [(0, 8, "k k-12-1-21 -- 4i")])
        ([(7, 1, "4o"), (8, 5, "4i")], [])
    equal (run 2 [(0, 8, "k_\\ -- 4i"), (8, 8, "k//\\\\ -- 4o")])
        ([(7, 1, "4o"), (8, 1, "4i")], [])

e_pattern :: RealTime -- ^ expect the first note at this time
    -> Derive.Result -> ([(Reyong.Voice, String)], [String])
e_pattern start = first (Gangsa_test.convert_to_pattern pitch_digit start)
    . e_by_voice DeriveTest.e_start_note

pitch_digit :: String -> String
pitch_digit p = drop 1 p

e_by_voice :: (Score.Event -> a) -> Derive.Result
    -> ([(Reyong.Voice, [a])], [String])
e_by_voice extract =
    first Seq.group_fst . DeriveTest.extract (\e -> (event_voice e, extract e))

event_voice :: Score.Event -> Reyong.Voice
event_voice = fromMaybe 0 . Env.maybe_val EnvKey.voice . Score.event_environ

e_voice :: Int -> (Score.Event -> a) -> Derive.Result -> (Maybe [a], [String])
e_voice voice extract = group_voices . DeriveTest.extract ex
    where
    ex e = (DeriveTest.e_environ_val EnvKey.voice e :: Maybe Int, extract e)
    group_voices = first (lookup (Just voice) . Seq.group_fst)

-- Force all the positions because of partial functions in there.
test_positions = forM_ Reyong.reyong_positions $ \pos -> equal pos pos

test_assign_positions = do
    let f pattern dest = extract $ Reyong.assign_positions pattern 5 dest
            (map Reyong.pos_cek Reyong.reyong_positions)
        extract = map (unwords . map show_pitch)
        p1 = Reyong.parse_kotekan "4-3" "12-"
    equal (f p1 0) ["3u 3a -", "4o - 4i", "4u 4a -", "5o - 5i"]
    equal (f p1 1) ["3a 4i -", "4e - 4o", "4a 5i -", "5e - 5o"]
    equal (f p1 2) ["3u - 3e", "4i 4o -", "4u - 4e", "5i 5o -"]
    equal (f p1 3) ["3a - 3u", "4o 4e -", "4a - 4u", "5o 5e -"]
    equal (f p1 4) ["3e 3u -", "4i - 3a", "4e 4u -", "5i - 4a"]

-- * tumpuk

test_tumpuk = do
    let run = DeriveTest.extract extract
            . DeriveTest.derive_tracks (title_with_damp 1.5) . UiTest.note_track
        extract e = (DeriveTest.e_note e, DeriveTest.e_attributes e)
    equal (run [(1, 4, "t xo 1 -- 4i")])
        ([((1, 1, "4i"), "+mute"), ((2, 3, "4i"), "+")], [])
    equal (run [(1, 4, "place=0 | t xo 1 -- 4i")])
        ([((0, 1, "4i"), "+mute"), ((1, 4, "4i"), "+")], [])
    strings_like (snd $ run [(1, 4, "t px0o 1 -- 4i")]) ["no prev pitch"]
    equal (run [(0, 1, "4o"), (1, 4, "t px0o 1 -- 4i")])
        ([((0, 1, "4o"), "+"), ((1, 1, "4o"), "+mute"), ((2, 3, "4i"), "+")],
            [])

test_tumpuk_patterns = do
    -- Force partial function.
    equal Reyong.tumpuk_patterns Reyong.tumpuk_patterns

test_select_pattern = do
    let f = Reyong.select_pattern
        rnds = [0, 1/16 .. 1]
        permutations dur = [f dur rnd1 rnd2 | rnd1 <- rnds, rnd2 <- rnds]
    let dur_of (notes, dur) = fromIntegral (length notes) * dur
        all_ok xs = (xs, replicate (length xs) (Right True))
        desired = (* (2/3))
    -- If there is lots of time, then patterns never exceed 2/3.
    uncurry equal
        (all_ok (map ((<= desired 16) . dur_of <$>) (permutations 16)))
    -- If there is not much time, patterns are either <=1 or Left.
    -- TODO test that
    left_like (first untxt $ f 0.1 0 0) "no patterns fit"

-- * damp

test_c_infer_damp = do
    let run = DeriveTest.extract extract
            . DeriveTest.derive_tracks (title_with_damp 1 <> " | %damp=.5")
            . UiTest.note_track
        extract e = (Score.event_start e, DeriveTest.e_pitch e,
            fromMaybe 0 $ DeriveTest.e_start_control Reyong.damp_control e)
    equal (run [(0, 1, "4i"), (1, 1, "+undamped -- 4o")])
        ([(0, "4i", 0.5), (1, "4o", 0)], [])
    equal (run [(0, 0.5, "4i"), (0.5, 0.5, "4o"), (1, 1, "4i")])
        ([(0, "4i", 0), (0.5, "4o", 0.5), (1, "4i", 0.5)], [])
    equal (run [(0, 1, "4i"), (1, 1, "4i")])
        ([(0, "4i", 0), (1, "4i", 0.5)], [])

test_c_infer_damp_kotekan = do
    let run = e_voice 1 extract . DeriveTest.derive_tracks (title_with_damp 1.5)
            . UiTest.note_track
        extract e = (Score.event_start e, DeriveTest.e_pitch e,
            fromMaybe 0 $ DeriveTest.e_start_control Reyong.damp_control e)
    equal (run [(0, 4, "k k-12-1-21 -- 4i")])
        (Just [(0, "3e", 0), (1, "3u", 1), (2, "3e", 1), (4, "3u", 1)], [])

test_infer_damp = do
    let f dur = Reyong.infer_damp (const dur) . mkevents
    -- Damp with the other hand.
    equal (f 1 [(0, "4c"), (1, "4d"), (2, "4e")]) [1, 1, 1]
    -- 4e can't be damped because both hands are busy.
    equal (f 1 [(0, "4d"), (1, "4e"), (2, "4f"), (2, "4d")]) [1, 0, 1, 1]
    -- First 4d can't damp because the same hand is busy, and the other
    -- hand is blocked by the same hand.
    equal (f 1.1 [(0, "4c"), (1, "4d"), (3, "4d"), (4, "4c")]) [1, 0, 1, 1]
    -- But give a bit more time and all is possible.
    equal (f 0.75 [(0, "4c"), (1, "4d"), (3, "4d"), (4, "4c")]) [1, 1, 1, 1]

test_assign_hands = do
    let f = map fst . Reyong.assign_hands . mkevents
    equal (f [(0, "4c"), (1, "4c"), (2, "4d"), (3, "4d"), (4, "4c")])
        [L, L, R, R, L]
    equal (f [(0, "4c"), (1, "4d"), (2, "4e")]) [L, R, R]
    equal (f [(0, "4d"), (1, "4e"), (2, "4f"), (2, "4d")]) [L, R, R, L]

mkevents :: [(RealTime, String)] -> [Score.Event]
mkevents =
    map $ DeriveTest.mkevent . (\(t, p) -> (t, 1, p, [], Score.empty_inst))

show_pitch :: Maybe Pitch.Pitch -> String
show_pitch Nothing = "-"
show_pitch (Just (Pitch.Pitch oct (Pitch.Degree d _))) =
    show oct ++ ("ioeua" !! d) : ""
