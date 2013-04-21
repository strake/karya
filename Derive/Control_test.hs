module Derive.Control_test where
import qualified Data.Map as Map

import Util.Control
import qualified Util.Log as Log
import Util.Test

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
    strings_like logs ["call not found: abc", "call not found: def"]
    equal (derive ("cont", events)) ([[(0, 1), (1, 2)]], [])

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
            (Control.derive_control True (mktrack 10 (0, 10) events) [])
    equal (derive [(0, 0, "1"), (1, 0, "2")])
        (Right ([(0, 1), (1, 2)], []))
    equal (derive [(0, 0, "1"), (2, 0, "i 2")])
        (Right ([(0, 1), (1, 1.5), (2, 2)], []))
    equal (derive [(0, 0, "1"), (2, 0, "i 2"), (4, 0, "i 1")])
        (Right ([(0, 1), (1, 1.5), (2, 2), (3, 1.5), (4, 1)], []))

    -- evaluation continues after an error
    equal (derive [(0, 0, "1"), (1, 0, "def")])
        (Right ([(0, 1)], ["Error: control call not found: def"]))
    equal (derive [(0, 0, "1"), (1, 0, "def"), (2, 0, "i 2")])
        (Right ([(0, 1), (1, 1.5), (2, 2)],
            ["Error: control call not found: def"]))

mktrack :: ScoreTime -> (ScoreTime, ScoreTime) -> [UiTest.EventSpec]
    -> TrackTree.TrackEvents
mktrack events_end track_range events =
    (TrackTree.track_events ">" evts events_end)
        { TrackTree.tevents_range = track_range }
    where evts = Events.from_list (map UiTest.make_event events)

test_pitch_track = do
    let derive = do_derive DeriveTest.e_nns

    let (val, logs) = derive ("*no-scale", [(0, 0, "1"), (1, 0, "2")])
    equal val []
    strings_like logs ["unknown ScaleId \"no-scale\""]

    let (val, logs) = derive ("*twelve", [(0, 0, "1"), (1, 0, "2")])
    equal val [[]]
    strings_like logs ["call not found: 1", "call not found: 2"]
    let (val, logs) = derive
            ("*twelve", [(0, 0, "4c"), (1, 0, "4d"), (2, 0, "4hc")])
    equal val [[(0, 60), (1, 62)]]
    strings_like logs ["call not found: 4hc"]
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
                . (Map.! Score.Control "cont") . Score.event_controls
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

test_stash_signal = do
    -- make sure that TrackSignals are recorded when control tracks are derived
    let itrack = (">i", [])
        ctrack = ("cont", [(0, 0, "1"), (1, 0, "0")])
        csig = Signal.signal [(0, 1), (1, 0)]
    let run = extract . DeriveTest.derive_tracks
        extract r = Log.trace_logs (snd $ DeriveTest.r_split r)
            (map e_tsig (Map.elems (Derive.r_track_signals r)))
    let tsig samples p x = Right (Signal.signal samples, p, x)

    equal (run [ctrack, itrack]) [Right (csig, 0, 1)]
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
    equal (run [ptrack, itrack]) [Right (psig, 0, 1)]

    -- Subtracks should be rendered, even though they're never evaluated as
    -- a whole.
    equal (run [itrack, ctrack]) [Right (csig, 0, 1)]
    equal (run [itrack, ("$ broken", [(0, 0, "0")])]) []
    equal (run [itrack, itrack]) []
    equal (run [itrack, ptrack]) [Right (psig, 0, 1)]

test_signal_default_tempo = do
    -- Signal is stretched by the default tempo.
    let r = extract $ DeriveTest.derive_tracks_with_ui id set_tempo
            [("*", [(0, 0, "4c"), (10, 0, "4d"), (20, 0, "4c")])]
        set_tempo = State.config#State.default_#State.tempo #= 2
        extract = map e_tsig . Map.elems . Derive.r_track_signals
    equal r [Right (Signal.signal [(0, 60), (5, 62), (10, 60)], 0, 0.5)]

e_tsig :: Either [Log.Msg] Track.TrackSignal
    -> Either [String] (Signal.Display, ScoreTime, ScoreTime)
e_tsig result = case result of
    Left logs -> Left $ map DeriveTest.show_log logs
    Right (Track.TrackSignal sig shift stretch _) ->
        Right (sig, shift, stretch)
