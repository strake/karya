-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.Control_test where
import qualified Data.Map as Map
import qualified Data.Set as Set

import Util.Control
import qualified Util.Seq as Seq
import Util.Test

import qualified Ui.Block as Block
import qualified Ui.Events as Events
import qualified Ui.State as State
import qualified Ui.Track as Track
import qualified Ui.TrackTree as TrackTree
import qualified Ui.UiTest as UiTest

import qualified Derive.Control as Control
import qualified Derive.Derive as Derive
import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.Score as Score

import qualified Perform.RealTime as RealTime
import qualified Perform.Signal as Signal
import Types


do_derive :: (Score.Event -> a) -> UiTest.TrackSpec -> ([a], [String])
do_derive extract track = DeriveTest.extract extract $
        DeriveTest.derive_tracks [(">", [(0, 8, "")]), track]

test_control_track = do
    let derive = do_derive (DeriveTest.e_control "cont")
    let events = [(0, 0, "1"), (1, 0, "2")]

    -- various failures
    let (val, logs) = derive ("*bork *bork *bork", events)
    equal val []
    strings_like logs ["track title: control track must be one of"]

    let (val, logs) = derive ("cont", [(0, 0, "abc"), (1, 0, "def")])
    equal val [[(0, 0)]]
    strings_like logs ["not found: abc", "not found: def"]
    equal (derive ("cont", events)) ([[(0, 1), (1, 2)]], [])

test_split_control = do
    let run = DeriveTest.derive_tracks_with_ui id DeriveTest.with_tsig
        e_controls = DeriveTest.extract $ \event ->
            let e name = DeriveTest.e_control name event
            in ('a', e "a", 'b', e "b")
        e_tsigs = map snd . DeriveTest.e_tsigs

    let tracks =
            [ (">", [(0, 4, "")])
            , ("a", [(0, 0, "1"), (1, 0, "%b"), (2, 0, "2")])
            ]
    equal (e_controls $ run tracks)
        ([('a', [(0, 1)], 'b', [(0, 0), (2, 2)])], [])
    equal (e_tsigs $ run tracks) [[(0, 1), (2, 2)]]

    let tracks =
            [ (">", [(0, 2, ""), (2, 2, "")])
            , ("a", [(0, 0, ".5"), (1, 0, "%b"), (2, 0, "1")])
            ]
    equal (e_controls $ run tracks)
        ( [ ('a', [(0, 0.5)], 'b', [(0, 0)])
          , ('a', [(0, 0.5)], 'b', [(2, 1)])
          ]
        , []
        )
    equal (e_tsigs $ run tracks) [[(0, 0.5), (2, 1)]]

    -- Tracks with the same name are merged.
    let tracks =
            [ (">", [(0, 2, ""), (2, 2, ""), (4, 2, "")])
            , ("a", [(0, 0, "1"), (1, 0, "%b"), (2, 0, "2"),
                (3, 0, "%a"), (4, 0, "3")])
            ]
    equal (e_controls $ run tracks)
        ( [ ('a', [(0, 1)], 'b', [(0, 0)])
          , ('a', [(0, 1)], 'b', [(2, 2)])
          , ('a', [(4, 3)], 'b', [(2, 2)])
          ]
        , []
        )
    equal (e_tsigs $ run tracks) [[(0, 1), (2, 2), (4, 3)]]

test_hex = do
    let derive events =
            do_derive (DeriveTest.e_control "cont") ("cont", events)
    equal (derive [(0, 0, "`0x`ff"), (1, 0, "`0x`33"), (2, 0, "`0x`00")])
        ([[(0, 1), (1, 0.2), (2, 0)]], [])

test_track_expression = do
    let derive = do_derive (DeriveTest.e_control "cont")
    equal (derive ("cont", [(0, 0, "0"), (4, 0, "i 1")]))
        ([[(0, 0), (1, 0.25), (2, 0.5), (3, 0.75), (4, 1)]], [])
    equal (derive ("cont | srate = 2", [(0, 0, "0"), (4, 0, "i 1")]))
        ([[(0, 0), (2, 0.5), (4, 1)]], [])

    let derive_pitch = do_derive DeriveTest.e_nns
    equal (derive_pitch ("*twelve | srate = 2",
            [(0, 0, "4c"), (4, 0, "i (4d)")]))
        ([[(0, 60), (2, 61), (4, 62)]], [])

test_derive_control = do
    let ex (sig, logs) = (Signal.unsignal sig, map DeriveTest.show_log logs)
    let derive events = DeriveTest.extract_run ex $ DeriveTest.run State.empty
            (Control.derive_control False True (mktrack 10 (0, 10) events) [])
    equal (derive [(0, 0, "1"), (1, 0, "2")])
        (Right ([(0, 1), (1, 2)], []))
    equal (derive [(0, 0, "1"), (2, 0, "i 2")])
        (Right ([(0, 1), (1, 1.5), (2, 2)], []))
    equal (derive [(0, 0, "1"), (2, 0, "i 2"), (4, 0, "i 1")])
        (Right ([(0, 1), (1, 1.5), (2, 2), (3, 1.5), (4, 1)], []))

    -- evaluation continues after an error
    equal (derive [(0, 0, "1"), (1, 0, "def")])
        (Right ([(0, 1)],
            ["Error: control generator or val call not found: def"]))
    equal (derive [(0, 0, "1"), (1, 0, "def"), (2, 0, "i 2")])
        (Right ([(0, 1), (1, 1.5), (2, 2)],
            ["Error: control generator or val call not found: def"]))

mktrack :: ScoreTime -> (ScoreTime, ScoreTime) -> [UiTest.EventSpec]
    -> TrackTree.TrackEvents
mktrack events_end track_range events =
    (TrackTree.track_events ">" evts events_end)
        { TrackTree.tevents_range = track_range }
    where evts = Events.from_list (map UiTest.make_event events)

test_tempo_hybrid = do
    let run start dur tempo events = DeriveTest.extract extent $
            DeriveTest.derive_blocks
                [ ("top", [(">", [(start, dur, "sub")])])
                , ("sub=ruler", [("tempo hybrid", tempo),
                    (">", [(n, 1, "") | n <- Seq.range' 0 events 1])])
                ]
        extent e = (Score.event_start e, Score.event_end e)
    -- Tempo is cancelled out by stretch_to_1 as usual.
    equal (run 0 2 [(0, 0, "1")] 4)
        ([(0, 0.5), (0.5, 1), (1, 1.5), (1.5, 2)], [])
    equal (run 0 2 [(0, 0, "2")] 4)
        ([(0, 0.25), (0.25, 0.5), (0.5, 0.75), (0.75, 1)], [])

    -- Absolute tempo, goes over event bounds.
    equal (run 0 2 [(0, 0, "0")] 4)
        ([(0, 1), (1, 2), (2, 3), (3, 4)], [])

    let tempo = [(0, 0, "0"), (2, 0, "1")]
    equalf 0.001 (run 0 3 tempo 4) ([(0, 1), (1, 2), (2, 2.5), (2.5, 3)], [])
    equalf 0.001 (run 0 4 tempo 4) ([(0, 1), (1, 2), (2, 3), (3, 4)], [])
    equalf 0.001 (run 0 6 tempo 4) ([(0, 1), (1, 2), (2, 4), (4, 6)], [])
    equalf 0.001 (run 2 4 tempo 4) ([(2, 3), (3, 4), (4, 5), (5, 6)], [])
    equalf 0.001 (run 2 6 tempo 4) ([(2, 3), (3, 4), (4, 6), (6, 8)], [])

test_pitch_track = do
    let derive = do_derive DeriveTest.e_nns

    let (val, logs) = derive ("*no-scale", [(0, 0, "1"), (1, 0, "2")])
    equal val []
    strings_like logs ["get_scale: unknown \\*no-scale"]

    let (val, logs) = derive ("*twelve", [(0, 0, "1"), (1, 0, "2")])
    equal val [[]]
    strings_like logs ["not found: 1", "not found: 2"]
    let (val, logs) = derive
            ("*twelve", [(0, 0, "4c"), (1, 0, "4d"), (2, 0, "4hc")])
    equal val [[(0, 60), (1, 62)]]
    strings_like logs ["not found: 4hc"]
    equal (derive ("*twelve", [(0, 0, "4c"), (1, 0, "4d")]))
        ([[(0, 60), (1, 62)]], [])
    equal (derive ("*twelve", [(0, 0, "4c"), (2, 0, "i (4d)")]))
        ([[(0, 60), (1, 61), (2, 62)]], [])

test_relative_control = do
    let run suf add_suf = extract $ DeriveTest.derive_tracks
            [ (">", [(0, 5, "")])
            , ("*", [(0, 0, "4c")])
            , ("cont" ++ suf, [(0, 0, "0"), (2, 0, "i 2"), (4, 0, "i 0")])
            , ("add cont" ++ add_suf, [(0, 0, "1")])
            ]
        extract = DeriveTest.extract $
            (\(Score.Typed typ sig) -> (typ, map (at sig) [0..5]))
                . (Map.! "cont") . Score.event_controls
        at sig t = Signal.at (RealTime.seconds t) sig
    equal (run "" "") ([(Score.Untyped, [1, 2, 3, 2, 1, 1])], [])
    -- No type on the relative signal means it gets the absolute signal's
    -- type.
    equal (run ":d" "") ([(Score.Diatonic, [1, 2, 3, 2, 1, 1])], [])
    -- And vice versa.
    equal (run "" ":d") ([(Score.Diatonic, [1, 2, 3, 2, 1, 1])], [])
    -- If they both have types, the absolute signal wins.
    equal (run ":c" ":d") ([(Score.Chromatic, [1, 2, 3, 2, 1, 1])], [])

    -- Putting relative and absolute in the wrong order is ok since addition
    -- is a monoid.
    let run2 c1 v1 c2 v2 = extract $ DeriveTest.derive_tracks
            [ (">", [(0, 10, "")])
            , (c1, [(0, 0, v1)])
            , (c2, [(0, 0, v2)])
            ]
        extract = DeriveTest.extract $ DeriveTest.e_control "cont"
    equal (run2 "add cont" "1" "add cont" "1") ([[(0, 2)]], [])
    -- Default is multiply, set replaces.
    equal (run2 "cont" ".5" "cont" ".5") ([[(0, 0.25)]], [])
    equal (run2 "cont" ".5" "set cont" ".5") ([[(0, 0.5)]], [])

test_default_merge = do
    let run control = DeriveTest.extract (DeriveTest.e_control
            (Score.control (txt control))) $ DeriveTest.derive_tracks
                [ (">", [(0, 4, "")])
                , (control, [(0, 0, ".5")])
                , (control, [(0, 0, ".5")])
                ]
    equal (run "dyn") ([[(0, 0.25)]], [])
    equal (run "t-diatonic") ([[(0, 1)]], [])

test_stash_signal = do
    -- make sure that TrackSignals are recorded when control tracks are derived
    let itrack = (">i", [])
        ctrack = ("cont", [(0, 0, "1"), (1, 0, "0")])
        csig = Signal.signal [(0, 1), (1, 0)]
    let run = e_tsigs . DeriveTest.derive_tracks_with_ui id DeriveTest.with_tsig
    let tsig samples p x = (Signal.signal samples, p, x)

    equal (run [ctrack, itrack]) [(csig, 0, 1)]
    -- Constant tempo stretches track sig.
    -- Tempo track itself is unstretched.
    -- Extra sample at the end of the tempo track due to the set-prev hack.
    let end = RealTime.score UiTest.default_block_end
    equal (run [("tempo", [(0, 0, "2")]), ctrack, itrack]) $
        [ tsig [(0, 2), (end, 2)] 0 1
        , tsig [(0, 1), (0.5, 0)] 0 0.5
        ]

    -- but a complicated tempo forces a rederive so output is still in
    -- RealTime
    equal (run [("tempo", [(0, 0, "2"), (4, 0, "i 1")]), ctrack, itrack])
        [ tsig [(0, 2), (1, 1.75), (2, 1.5), (3, 1.25), (4, 1), (end, 1)] 0 1
        , tsig [(0, 1), (1, 0)] 0 1
        ]

    -- pitch tracks work too
    let ptrack = ("*twelve", [(0, 0, "4c"), (1, 0, "4d")])
        psig = Signal.signal [(0, 60), (1, 62)]
    equal (run [ptrack, itrack]) [(psig, 0, 1)]

    -- Subtracks should be rendered, even though they're never evaluated as
    -- a whole.
    equal (run [itrack, ctrack]) [(csig, 0, 1)]
    equal (run [itrack, ("$ broken", [(0, 0, "0")])]) []
    equal (run [itrack, itrack]) []
    equal (run [itrack, ptrack]) [(psig, 0, 1)]

test_signal_default_tempo = do
    -- Signal is stretched by the default tempo.
    let r = e_tsigs $ DeriveTest.derive_tracks_with_ui id
            (DeriveTest.with_tsig . set_tempo)
            [("*", [(0, 0, "4c"), (10, 0, "4d"), (20, 0, "4c")])]
        set_tempo = State.config#State.default_#State.tempo #= 2
    equal r [(Signal.signal [(0, 60), (5, 62), (10, 60)], 0, 0.5)]

test_derive_track_signals = do
    let run wanted t2 t3 = DeriveTest.derive_tracks_with (set_wanted wanted)
            [(">", [(0, 8, "+a")]), t2, t3]
        set_wanted wanted = DeriveTest.modify_constant $ \st -> st
            { Derive.state_wanted_track_signals =
                Set.fromList $
                    map (((,) UiTest.default_block_id) . UiTest.mk_tid) wanted
            }
        e_ts r = [(tid, Signal.unsignal sig)
            | ((_, tid), (sig, _, _)) <- e_tsig_tracks r]

    equal (e_ts $ run [] ("c1", [(0, 0, "1")]) ("c2", [(0, 0, "2")])) []
    -- Child track causes both to get signals.
    equal (e_ts $ run [3] ("c1", [(0, 0, "1")]) ("c2", [(0, 0, "2")]))
        [ (UiTest.mk_tid 2, [(0, 1)])
        , (UiTest.mk_tid 3, [(0, 2)])
        ]

    equal (e_ts $ run [3]
            ("speed", [(0, 0, "1")])
            ("*", [(0, 0, "tr (4c) 1c %speed"), (4, 0, "4c")]))
        [ (UiTest.mk_tid 2, [(0, 1)])
        , (UiTest.mk_tid 3, [(0, 60), (1, 61), (2, 60), (3, 61), (4, 60)])
        ]
    equal (e_ts $ run [3]
            ("speed", [(0, 0, "1"), (2, 0, "2")])
            ("*", [(0, 0, "tr (4c) 1c %speed"), (4, 0, "4c")]))
        [ (UiTest.mk_tid 2, [(0, 1), (2, 2)])
        , (UiTest.mk_tid 3,
            [ (0, 60), (1, 61), (2, 60), (2.5, 61), (3, 60), (3.5, 61), (4, 60)
            ])
        ]

    -- Not fooled by two levels of note tracks.
    let run_lin = DeriveTest.derive_tracks_with_ui id
            (DeriveTest.with_tsig . DeriveTest.with_linear)
    equal (e_ts $ run_lin $
            [ (">vln", [(1, 1, "+pizz")])
            , (">vln", [(0, 1, ""), (1, 1, "")])
            , ("*", [(0, 0, "4c")])
            ])
        [(UiTest.mk_tid 3, [(0, 60)])]

    -- -- Control modifications show up in the signal.
    -- -- Except I don't want to do this anymore, see comment in
    -- -- 'Control.eval_signal'.
    -- let result = run [3] ("*", [(0, 0, "4c"), (2, 0, "drop 1c 2")])
    --         ("dyn", [(0, 0, ".5")])
    -- equal (e_ts result)
    --     [ (UiTest.mk_tid 2, [(0, 60), (3, 59.5), (4, 59)])
    --     , (UiTest.mk_tid 3, [(0, 0.5), (2, 0.5), (3, 0.25), (4, 0)])
    --     ]

test_track_signal_multiple = do
    -- If a track shows up in multiple blocks, it should get multiple
    -- TrackSignals.
    let (bid, state) = UiTest.run State.empty $ do
            (bid1, [tid, _]) <- UiTest.mkblock
                ("b1", [("c", [(0, 0, "1")]), (">", [(0, 1, "b2")])])
            (bid2, _) <- UiTest.mkblock ("b2", [(">", [(0, 1, "")])])
            State.insert_track bid2 2 $ Block.track
                (Block.TId tid UiTest.default_ruler_id) 20
            return bid1
    let tsigs = map fst $ e_tsig_tracks $ DeriveTest.derive_block
            (DeriveTest.with_tsig state) bid
    equal tsigs
        [ (UiTest.bid "b1", UiTest.mk_tid_name "b1" 1)
        , (UiTest.bid "b2", UiTest.mk_tid_name "b1" 1)
        ]

test_prev_val = do
    let run ex tracks = DeriveTest.extract ex $ DeriveTest.derive_tracks $
            (">", [(0, 1, ""), (1, 1, ""), (2, 1, "")]) : tracks
    equal (run (DeriveTest.e_control "c")
            [("c", [(0, 0, ".5"), (1, 0, "'"), (2, 0, "'")])])
        ([[(0, 0.5)], [(1, 0.5)], [(2, 0.5)]], [])


e_tsigs :: Derive.Result -> [(Signal.Display, ScoreTime, ScoreTime)]
e_tsigs = map snd . e_tsig_tracks

e_tsig_tracks :: Derive.Result
    -> [((BlockId, TrackId), (Signal.Display, ScoreTime, ScoreTime))]
e_tsig_tracks = map (second extract) . Map.toList . Derive.r_track_signals
    where
    extract (Track.TrackSignal sig shift stretch _) = (sig, shift, stretch)
