-- Copyright 2014 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Kendang patches for "Local.Instrument.Kontakt".
module Local.Instrument.KontaktKendang where
import qualified Data.List as List
import qualified Data.Map as Map

import Util.Control
import qualified Midi.Key as Key
import qualified Midi.Key2 as Key2
import qualified Midi.Midi as Midi

import qualified Cmd.Cmd as Cmd
import qualified Cmd.Instrument.CUtil as CUtil
import qualified Cmd.Instrument.Drums as Drums

import qualified Derive.Attrs as Attrs
import qualified Derive.Call as Call
import qualified Derive.Call.Tags as Tags
import qualified Derive.Derive as Derive
import qualified Derive.Score as Score
import Derive.Score (attr)
import qualified Derive.Sig as Sig
import qualified Derive.TrackLang as TrackLang

import qualified Perform.Midi.Instrument as Instrument
import qualified Perform.NN as NN
import qualified App.MidiInst as MidiInst


pb_range :: Instrument.PbRange
pb_range = (-24, 24)

patches :: [MidiInst.Patch]
patches =
    [ (CUtil.pitched_drum_patch tunggal_notes $ inst "kendang", tunggal_code)
    , (CUtil.drum_patch old_tunggal_notes $ inst "kendang-old", tunggal_code)
    , (inst "kendang-pasang", pasang_code)
    ]
    where
    tunggal_code = CUtil.drum_code (Just "kendang-tune") (map fst tunggal_notes)
    inst name = Instrument.patch $ Instrument.instrument name [] pb_range

tunggal_notes :: CUtil.PitchedNotes
tunggal_notes = do
    (char, call, attrs) <- tunggal_calls
    let Just ks_range = lookup (Score.attrs_remove soft attrs) tunggal_keymap
    let note = Drums.Note call attrs char
            (if Score.attrs_contain attrs soft then 0.3 else 1)
    return (note, ks_range)

tunggal_keymap :: [(Score.Attributes, CUtil.KeyswitchRange)]
tunggal_keymap = CUtil.make_keymap Key2.e_2 Key2.c_1 12 NN.fs3
    [ [de <> Attrs.staccato, plak]
    , [de <> Attrs.thumb]
    , [de, dag]
    , [de <> Attrs.mute, tek]
    , [tut]
    , [ka]
    , [pang]
    , [pak]
    , [de <> Attrs.left, tut <> Attrs.left]
    ]

tunggal_calls :: [(Char, TrackLang.CallId, Score.Attributes)]
tunggal_calls =
    [ ('b', "PL", plak)
    -- left
    , ('q', "P", pak)
    , ('w', "T", pang)
    , ('1', "^", pak <> soft)
    , ('e', "Ø", tut <> Attrs.left)
    , ('r', "`O+`", de <> Attrs.left)
    -- right
    , ('z', "+", de)
    , ('a', "-", de <> soft)
    , ('s', "+.", de <> Attrs.thumb)
    , ('d', "+/", de <> Attrs.staccato)
    , ('x', "o", tut)
    , ('c', ".", ka <> soft)
    , ('f', "..", ka)
    , ('.', "<", dag)
    , ('l', "-<", dag <> soft)
    , ('/', "[", tek)
    , (';', "-[", tek <> soft)
    ]

-- | Mapping for the old kendang patches.
old_tunggal_notes :: [(Drums.Note, Midi.Key)]
old_tunggal_notes = map make_note
    [ (plak, Key.g1)
    -- left
    , (pak, Key.c5)
    , (pang, Key.g4)
    , (pak <> soft, Key.c5)
    , (de <> Attrs.left, Key.d4)
    , (tut <> Attrs.left, Key.c4)
    -- right
    , (de, Key.c2)
    , (de <> soft, Key.c2)
    , (de <> Attrs.thumb, Key.f2)
    , (de <> Attrs.staccato, Key.c1)
    , (tut, Key.c3)
    , (ka <> soft, Key.g3)
    , (ka, Key.g3)
    , (dag, Key.c2)
    , (dag <> soft, Key.c2)
    , (tek <> soft, Key.c1)
    , (tek, Key.c1)
    ]
    where
    make_note (attrs, key) = (note, key)
        where
        note = Drums.Note call attrs char
            (if Score.attrs_contain attrs soft then 0.3 else 1)
        Just (char, call, _) =
            List.find (\(_, _, a) -> a == attrs) tunggal_calls


-- * pasang

data Kendang = Wadon | Lanang deriving (Show, Eq)
type Pasang = (Score.Instrument, Score.Instrument)

pasang_inst :: Kendang -> Pasang -> Score.Instrument
pasang_inst Wadon = fst
pasang_inst Lanang = snd

-- | (keybinding, call_name, Kendang, dispatch_to_call)
--
-- The dispatch calls should all be understood by a kendang tunggal, i.e.
-- in 'tunggal_calls'.
pasang_calls :: [(Char, TrackLang.CallId, Kendang, TrackLang.CallId)]
pasang_calls =
    [ ('b', "PL", Wadon, "PL")
    , ('t', "Ø", Lanang, "Ø")
    -- left
    , ('q', "k", Wadon, "P") -- ka
    , ('w', "P", Lanang, "P") -- pak
    , ('e', "t", Wadon, "T") -- kam
    , ('r', "T", Lanang, "T") -- pang
    -- right
    , ('z', "+", Wadon, "+") -- de
    , ('a', "-", Wadon, "-") -- de
    , ('x', "o", Lanang, "+") -- tut
    , ('c', "u", Wadon, "o") -- kum
    , ('v', "U", Lanang, "o") -- pung
    , ('m', "<", Wadon, "<") -- dag
    , ('j', "-<", Wadon, "-<") -- dag
    , (',', ">", Lanang, "<") -- dug
    , ('.', "[", Wadon, "[") -- tak
    , ('/', "]", Lanang, "[") -- tek
    ]

pasang_code :: MidiInst.Code
pasang_code =
    MidiInst.note_transformers [("realize", c_realize_kendang)]
    <> MidiInst.note_generators c_pasang_calls
    <> MidiInst.cmd pasang_cmd

pasang_cmd :: Cmd.Cmd
pasang_cmd = CUtil.insert_call $ Map.fromList
    [(char, name) | (char, name, _, _) <- pasang_calls]

c_pasang_calls :: [(TrackLang.CallId, Derive.Generator Derive.Note)]
c_pasang_calls =
    [(name, dispatch kendang call) | (_, name, kendang, call) <- pasang_calls]

-- | Create a call that just dispatches to another call, possibly transformed.
dispatch :: Kendang -> TrackLang.CallId -> Derive.Generator Derive.Note
dispatch kendang call = Derive.make_call name (Tags.inst <> Tags.bali)
    "Dispatch to wadon or lanang." $ Sig.call pasang_env $ \pasang args ->
        Derive.with_instrument (pasang_inst kendang pasang) $
            Call.reapply_gen args call
    where name = showt kendang <> " " <> prettyt call

c_realize_kendang :: Derive.Transformer Derive.Note
c_realize_kendang = Derive.transformer "realize-kendang"
    (Tags.inst <> Tags.bali <> Tags.postproc)
    "Realize a composite kendang score into separate lanang and wadon parts."
    $ Sig.callt pasang_env
    $ \pasang _args deriver -> realize_kendang pasang <$> deriver

pasang_env :: Sig.Parser Pasang
pasang_env = (,)
    <$> Sig.required_environ "wadon" Sig.Unprefixed "Wadon instrument."
    <*> Sig.required_environ "lanang" Sig.Unprefixed "Lanang instrument."

{- | Given a composite part with lanang and wadon, fill in the secondary
    strokes.

    The realization is not correct because I don't yet fully understand how it
    works.

    > c kPtTtT+o+oo-+
    > l .P.TPTP+^++.^
    > w P.TPTP+.+.^-+

    > c kPktT t T T t T .kP.tT.tTØØØ
    > l .P.^T P T T P T .^P^.T .TØØØ
    > w P^.TP T P P T P .P^.TP.TP. .

    > c kP+otT kPkP+o+o kPuUtT+o
    > l P.+.T^ P.P.+.+. P.o.T^+.
    > w .P.+.T .P.P.+.+ .P.O.T^+

    > c kPtTtT
    > l .P.TPTP
    > w P.TPTP

    > tTkPtTkP
    > T.P.T.P
    > .T.P.T.P

    > tT+otT+o
    > TP+.TP+.
    > .TP+.TP+
-}
realize_kendang :: Pasang -> Derive.Events -> Derive.Events
realize_kendang _pasang events = events -- TODO


-- * attrs

-- Kendang tunggal strokes don't really have names so I made some up.
-- For composite it would be: de tut, kum pung, ka pak, kam pang
-- If I took the wadon or lanang names, it would be de, kum, ka, kam, or
-- tut, pung, pak, pang, which both sound weird.

soft = attr "soft"

-- both
plak = attr "plak"

-- right
de = attr "de"
tut = attr "tut"
ka = attr "ka" -- neutral stroke
dag = attr "dag" -- de with panggul
tek = attr "tek"

-- left
pak = attr "pak"
pang = attr "pang" -- rim