-- Copyright 2014 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Kendang patches for "Local.Instrument.Kontakt".
module Local.Instrument.Kontakt.Kendang where
import qualified Data.List as List
import qualified Data.Map as Map

import qualified Midi.Key as Key
import qualified Midi.Key2 as Key2
import qualified Midi.Midi as Midi

import qualified Cmd.Cmd as Cmd
import qualified Cmd.Instrument.CUtil as CUtil
import qualified Cmd.Instrument.Drums as Drums
import qualified Cmd.Instrument.MidiConfig as MidiConfig
import qualified Cmd.Instrument.MidiInst as MidiInst

import qualified Derive.Attrs as Attrs
import qualified Derive.Call.Module as Module
import qualified Derive.Call.Tags as Tags
import qualified Derive.Derive as Derive
import qualified Derive.Eval as Eval
import qualified Derive.Score as Score
import Derive.Score (attr)
import qualified Derive.Sig as Sig
import qualified Derive.TrackLang as TrackLang

import qualified Perform.Midi.Instrument as Instrument
import qualified Perform.NN as NN
import qualified Local.Instrument.Kontakt.Util as Util
import Global


pb_range :: Instrument.PbRange
pb_range = (-24, 24)

patches :: [MidiInst.Patch]
patches =
    [ (CUtil.pitched_drum_patch tunggal_notes $ patch "kendang", tunggal_code)
    , (CUtil.drum_patch old_tunggal_notes $ patch "kendang-old", tunggal_code)
    , (Instrument.triggered $ patch "kendang-pasang", pasang_code)
    ]
    where
    tunggal_code = CUtil.drum_code (Just "kendang-tune") (map fst tunggal_notes)
    patch name = Instrument.patch $ Instrument.instrument name [] pb_range

tunggal_notes :: CUtil.PitchedNotes
tunggal_notes = do
    (char, call, attrs, group) <- tunggal_calls
    let Just ks_range = lookup (Score.attrs_remove soft attrs) tunggal_keymap
    let note = (Drums.note_dyn char call attrs dyn) { Drums.note_group = group }
        dyn = if Score.attrs_contain attrs soft then 0.3 else 1
    return (note, ks_range)

tunggal_keymap :: [(Score.Attributes, CUtil.KeyswitchRange)]
tunggal_keymap = CUtil.make_keymap Key2.e_2 Key2.c_1 12 NN.fs3
    [ [de <> Attrs.staccato, plak]
    , [de <> Attrs.thumb, dag <> Attrs.staccato]
    , [de, dag]
    , [de <> Attrs.closed, tek]
    , [tut]
    , [ka]
    , [pang]
    , [pak]
    , [de <> Attrs.left, tut <> Attrs.left]
    ]

tunggal_calls :: [(Char, TrackLang.CallId, Score.Attributes, Drums.Group)]
kendang_stops :: [(Drums.Group, [Drums.Group])]
(kendang_stops, tunggal_calls) = (,) stops $
    [ ('b', "PL", plak,                 both)
    -- left
    , ('q', "P", pak,                   left_closed)
    , ('w', "T", pang,                  left_open)
    , ('1', "^", pak <> soft,           left_closed)
    , ('e', "Ø", tut <> Attrs.left,     left_open)
    , ('r', "`O+`", de <> Attrs.left,   left_open)
    -- right
    , ('z', "+", de,                    right_open)
    , ('a', "-", de <> soft,            right_open)
    , ('s', "+.", de <> Attrs.thumb,    right_open)
    , ('d', "+/", de <> Attrs.staccato, right_open)
    , ('x', "o", tut,                   right_open)
    , ('c', ".", ka <> soft,            right_closed)
    , ('f', "..", ka,                   right_closed)
    , ('.', "<", dag,                   right_open)
    , ('l', "-<", dag <> soft,          right_open)
    , ('/', "[", tek,                   right_closed)
    , (';', "-[", tek <> soft,          right_closed)
    ]
    where
    stops =
        [ (both, [left_open, right_open])
        , (left_closed, [left_open])
        , (right_closed, [right_open])
        ]
    both = "both"
    left_closed = "left-closed"
    left_open = "left-open"
    right_closed = "right-closed"
    right_open = "right-open"

-- | Mapping for the old kendang patches.
old_tunggal_notes :: [(Drums.Note, Midi.Key)]
old_tunggal_notes = map (first make_note)
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
    make_note attrs = Drums.note_dyn char call attrs
            (if Score.attrs_contain attrs soft then 0.3 else 1)
        where
        Just (char, call, _, _) = List.find ((==attrs) . attrs_of) tunggal_calls
    attrs_of (_, _, a, _) = a

write_ksp :: IO ()
write_ksp = mapM_ (uncurry Util.write)
    [ ("kendang.ksp", Util.drum_mute_ksp "kendang" tunggal_notes kendang_stops)
    ]

-- * config

-- | @LInst.merge $ KontaktKendang.config ...@
config :: Text -> Text -> MidiConfig.Config
config name dev_ = MidiConfig.config
    [ (name <> "-wadon", "kontakt/kendang", Instrument.config1 dev 0)
    , (name <> "-lanang", "kontakt/kendang", Instrument.config1 dev 1)
    , (name, "kontakt/kendang-pasang",
        MidiConfig.environ "wadon" (inst $ name <> "-wadon") $
        MidiConfig.environ "lanang" (inst $ name <> "-lanang") $
        Instrument.config [])
    ]
    where
    dev = Midi.write_device dev_
    inst = Score.Instrument

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
dispatch kendang call = Derive.make_call Module.instrument name Tags.inst
    "Dispatch to wadon or lanang." $ Sig.call pasang_env $ \pasang args ->
        Derive.with_instrument (pasang_inst kendang pasang) $
        Eval.reapply_generator args call
    where name = showt kendang <> " " <> pretty call

c_realize_kendang :: Derive.Transformer Derive.Note
c_realize_kendang = Derive.transformer Module.instrument "realize-kendang"
    (Tags.inst <> Tags.postproc)
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