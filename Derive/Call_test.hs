-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.Call_test where
import qualified Data.Map as Map

import Util.Control
import qualified Util.Log as Log
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq
import Util.Test

import qualified Ui.Event as Event
import qualified Ui.UiTest as UiTest
import qualified Cmd.Cmd as Cmd
import qualified Derive.Args as Args
import qualified Derive.Attrs as Attrs
import qualified Derive.Call as Call
import qualified Derive.Call.CallTest as CallTest
import qualified Derive.Call.Sub as Sub
import qualified Derive.Call.Util as Util
import qualified Derive.Derive as Derive
import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.Environ as Environ
import qualified Derive.Instrument.DUtil as DUtil
import qualified Derive.Scale.Legong as Legong
import qualified Derive.Score as Score
import qualified Derive.Sig as Sig
import qualified Derive.Stack as Stack
import qualified Derive.TrackLang as TrackLang

import qualified Perform.Midi.Instrument as Instrument
import qualified Instrument.MidiDb as MidiDb
import qualified App.MidiInst as MidiInst


test_assign_controls = do
    let run inst_title cont_title val = extract $ DeriveTest.derive_tracks
            [ (cont_title, [(0, 0, val)])
            , ("*twelve", [(0, 0, "4c")])
            , (inst_title, [(0, 1, "")])
            ]
        extract = DeriveTest.extract $ \e ->
            (DeriveTest.e_pitch e, DeriveTest.e_control "cont" e)

    -- normal
    equal (run ">i" "cont" "1") ([("4c", [(0, 1)])], [])
    -- not seen
    equal (run ">i" "gont" "1") ([("4c", [])], [])

    -- a non-existent control with no default is an error
    let (events, logs) = run ">i | %cont = %bonk" "gont" "1"
    equal events []
    strings_like logs ["not found: Control \"bonk\""]
    -- control assigned
    equal (run ">i | %cont = %gont" "gont" "1") ([("4c", [(0, 1)])], [])

    -- set a constant signal
    equal (run ">i | %cont = 42" "gont" "1") ([("4c", [(0, 42)])], [])
    -- set constant signal with a default
    equal (run ">i | %cont = %gont,42" "bonk" "1") ([("4c", [(0, 42)])], [])
    equal (run ">i | %cont = %gont,42" "gont" "1") ([("4c", [(0, 1)])], [])

    -- named pitch doesn't show up
    equal (run ">i" "*twelve #foo" "2c") ([("4c", [])], [])
    -- assigned to default pitch, so it shows up
    equal (run ">i | # = #foo" "*twelve #foo" "2c") ([("2c", [])], [])
    -- set constant pitch
    equal (run ">i | # = (1c)" "*twelve #foo" "2c") ([("1c", [])], [])

test_environ_across_tracks = do
    let run tracks = DeriveTest.extract (DeriveTest.e_control "cont") $
            DeriveTest.derive_tracks ((">", [(0, 10, "")]) : tracks)

    -- first make sure srate works as I expect
    let interpolated = [(0, 0), (1, 0.25), (2, 0.5), (3, 0.75), (4, 1)]
    equal (run [("cont", [(0, 0, "0"), (4, 0, "i 1")])])
        ([interpolated], [])
    equal (run [("set cont | srate = 2", [(1, 0, "0"), (5, 0, "i 1")])])
        ([[(1, 0), (3, 0.5), (5, 1)]], [])

    -- now make sure srate in one track doesn't affect another
    let cont = ("cont", [(0, 0, "0"), (4, 0, "i 1")])
    equal (run [("cont2 | srate = 2", []), cont])
        ([interpolated], [])
    equal (run [cont, ("cont2 | srate = 2", [])])
        ([interpolated], [])

test_call_errors = do
    let derive = extract . DeriveTest.derive_tracks_with with_trans
        with_trans = CallTest.with_note_transformer "test-t" trans
        extract r = case DeriveTest.extract DeriveTest.e_event r of
            (val, []) -> Right val
            (_, logs) -> Left $ Seq.join "\n" logs

    let run_title title = derive [(title, [(0, 1, "--1")])]
    left_like (run_title ">i | no-such-call")
        "note transformer not found: no-such-call"
    left_like (run_title ">i | test-t *bad-arg") "expected Control but got"
    left_like (run_title ">i | test-t 1 2 3 4") "too many arguments"
    left_like (run_title ">i | test-t") "not found and no default"
    left_like (run_title ">i | test-t _") "not found and no default"
    left_like (run_title ">i | test-t %delay") "not found and no default"

    let run_evt evt = derive [(">i", [(0, 1, evt)])]
    left_like (run_evt "no-such-call")
        "note generator or val not found: no-such-call"
    let tr_result = extract $ DeriveTest.derive_tracks
            [(">", [(0, 4, "")]), ("*twelve", [(0, 0, "tr")])]
    left_like tr_result "ArgError: expected another argument"
    equal (run_evt "test-t 2 | test-t 1 |")
        (Right [(0, 1, "test-t 2 | test-t 1 |")])
    where
    trans = Derive.transformer "trans" mempty "doc" $ Sig.callt
        (Sig.defaulted "arg1" (Sig.required_control "test") "doc") $
        \c _args deriver -> do
            Util.control_at c 0
            deriver

test_val_call = do
    let extract = DeriveTest.extract (DeriveTest.e_control "cont")
    let run evt = extract $ DeriveTest.derive_tracks_with with_add1
            [(">", [(0, 1, "")]), ("cont", [(0, 0, evt)])]
        with_add1 = CallTest.with_val_call "add1" add_one
    equal (run "foobar")
        ([[(0, 0)]], ["Error: control generator or val not found: foobar"])
    equal (run "set 1") ([[(0, 1)]], [])
    equal (run "set (add1 1)") ([[(0, 2)]], [])
    equal (run "set (add1 (add1 1))") ([[(0, 3)]], [])
    let (res, logs) = run "set (add1 1 2)"
    equal res [[(0, 0)]]
    strings_like logs ["too many arguments"]
    where
    add_one :: Derive.ValCall
    add_one = Derive.val_call "add" mempty "doc" $ Sig.call
        (Sig.required "v" "doc") $
        \val _ -> return (TrackLang.num (val + 1))

test_inst_call = do
    let extract = DeriveTest.extract (Score.attrs_list . Score.event_attributes)
    let run inst = extract $ DeriveTest.derive_tracks_with
            (set_lookup_inst lookup_inst)
            [(inst, [(0, 1, "sn")])]
    equal (run ">s/1")
        ([], ["Error: note generator or val not found: sn"])
    equal (run ">s/with-call")
        ([["snare"]], [])

test_recursive_call = do
    let extract = DeriveTest.extract DeriveTest.e_event
    let result = extract $ DeriveTest.derive_tracks_with with_recur
            [(">", [(0, 1, "recur")])]
        with_recur = CallTest.with_note_generator "recur" recursive
    equal result ([], ["Error: call stack too deep: recursive"])
    where
    recursive :: Derive.Generator Derive.Note
    recursive = Derive.make_call "recursive" mempty "doc" $ Sig.call0 $
        \args -> Call.reapply_call args "recur" []

test_events_around = do
    -- Ensure sliced inverting notes still have access to prev and next events
    -- via the tevents_around hackery.
    let logs = extract $ DeriveTest.derive_tracks_with with_call
            [ (">", [(0, 1, ""), (1, 1, "around"), (2, 1, "")])
            , ("*twelve", [(0, 0, "4c"), (2, 0, "4d")])
            ]
        with_call = CallTest.with_note_generator "around" c_around
        extract = DeriveTest.r_log_strings
    equal logs ["prev: [0.0]", "next: [2.0]"]

    where
    c_around = Derive.make_call "around" mempty "doc" $ Sig.call0 $
        Sub.inverting $ \args -> do
            Log.warn $ "prev: "
                ++ show (map Event.start (Args.prev_events args))
            Log.warn $ "next: "
                ++ show (map Event.start (Args.next_events args))
            return []

test_inverting_around = do
    -- Ensure calls that want to look at the next pitch work, with the help of
    -- events around and inverting_around.
    let (evts, logs) = extract $ DeriveTest.derive_tracks_with with_call
            [ (">", [(0, 1, ""), (1, 1, "next"), (2, 1, "")])
            , ("*twelve", [(0, 0, "4c"), (2, 0, "4d")])
            ]
        with_call = CallTest.with_note_generator "next" c_next
        extract = DeriveTest.extract DeriveTest.e_note
    equal evts [(0, 1, "4c"), (1, 1, "4d"), (2, 1, "4d")]
    equal logs []
    where
    c_next = Derive.make_call "next" mempty "doc" $ Sig.call0 $
        Sub.inverting_around (2, 2) $ \args -> do
            next <- Derive.require "next event" $ Args.next_start args
            next_pitch <- Derive.require "next pitch"
                =<< Derive.pitch_at =<< Derive.real next
            Derive.d_at (Args.start args) $ Util.pitched_note next_pitch 1

test_track_dynamic = do
    let extract = map extract1 . Map.assocs . Derive.r_track_dynamic
        extract1 ((bid, tid), dyn) =
            (bid, tid,
                TrackLang.lookup_val Environ.scale env,
                TrackLang.lookup_val Environ.instrument env)
            where env = Derive.state_environ dyn
    let res = DeriveTest.derive_blocks
            [ ("b", [("*legong", [(0, 0, "1")]), (">i1", [(0, 1, "sub")])])
            , ("sub", [(">", [(0, 1, "")]), ("*", [(0, 0, "2")])])
            ]
    let inst = Just $ TrackLang.VInstrument $ Score.Instrument "i1"
        scale = Just $ TrackLang.VSymbol $
            TrackLang.scale_id_to_sym Legong.scale_id
    equal (extract res)
        [ (UiTest.bid "b", UiTest.mk_tid_name "b" 1, scale, Nothing)
        , (UiTest.bid "b", UiTest.mk_tid_name "b" 2, scale, inst)
        , (UiTest.bid "sub", UiTest.mk_tid_name "sub" 1, scale, inst)
        , (UiTest.bid "sub", UiTest.mk_tid_name "sub" 2, scale, inst)
        ]

test_track_dynamic_invert = do
    -- Ensure the correct TrackDynamic is collected even in the presence of
    -- inversion.
    let run = extract . DeriveTest.derive_tracks
        extract = Map.toList . Map.map (e_env . Derive.state_environ)
            . Derive.r_track_dynamic
        e_env e = (lookup Environ.instrument e, lookup Environ.scale e)
        lookup val = Pretty.pretty . TrackLang.lookup_val val
    -- Both tracks get *legong, even though >inst has to be inverted to see it.
    equal (run [(">inst", [(0, 0, "")]), ("*legong", [(0, 0, "1")])])
        [ ((UiTest.default_block_id, UiTest.mk_tid 1), (">inst", "legong"))
        , ((UiTest.default_block_id, UiTest.mk_tid 2), (">inst", "legong"))
        ]

test_note_transformer_stack = do
    -- The stack should be correct even in the presence of slicing and
    -- inversion.
    let (stacks, logs) = DeriveTest.extract Score.event_stack $
            DeriveTest.derive_tracks_linear
                [ (">", [(1, 1, "ap")])
                , (">", [(1, 1, "")])
                , ("*", [(0, 0, "4c")])
                ]
    equal logs []
    equal (map Stack.to_ui stacks)
        [[(Just UiTest.default_block_id, Just (UiTest.mk_tid 2), Just (1, 2))]]

-- * implementation

patch :: Instrument.Patch
patch =
    Instrument.attribute_map #= Instrument.simple_keymap [(Attrs.snare, 42)] $
    Instrument.patch (Instrument.instrument "with-call" [] (-1, 1))

midi_db :: MidiDb.MidiDb Cmd.InstrumentCode
(midi_db, _) = MidiDb.midi_db sdescs
    where
    sdescs = MidiInst.make $ (MidiInst.softsynth "s" "test synth" (-2, 2) [])
        { MidiInst.extra_patches = [(patch, code)] }
    code = MidiInst.note_generators [("sn", DUtil.attrs_note Attrs.snare)]

lookup_inst :: Score.Instrument -> Maybe Derive.Instrument
lookup_inst = fmap Cmd.derive_instrument . MidiDb.lookup_instrument midi_db

set_lookup_inst :: (Score.Instrument -> Maybe Derive.Instrument)
    -> Derive.Deriver d -> Derive.Deriver d
set_lookup_inst lookup_inst deriver = do
    Derive.modify $ \st -> st
        { Derive.state_constant = (Derive.state_constant st)
            { Derive.state_lookup_instrument = lookup_inst }
        }
    deriver
