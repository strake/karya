-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Native Instruments' Kontakt sampler.
--
-- Unfortunately the instruments here have to be hardcoded unless I want to
-- figure out how to parse .nki files or something.
module User.Elaforge.Instrument.Kontakt where
import qualified Data.Map as Map
import qualified Data.Tuple as Tuple

import qualified Midi.CC as CC
import qualified Midi.Key as Key
import qualified Midi.Key2 as Key2
import qualified Midi.Midi as Midi

import qualified Cmd.Cmd as Cmd
import qualified Cmd.Instrument.CUtil as CUtil
import qualified Cmd.Instrument.MidiInst as MidiInst
import qualified Cmd.Keymap as Keymap
import qualified Cmd.Msg as Msg

import qualified Derive.Args as Args
import qualified Derive.Attrs as Attrs
import qualified Derive.C.Prelude.Articulation as Articulation
import qualified Derive.C.Prelude.Highlight as Highlight
import qualified Derive.C.Prelude.Note as Note
import qualified Derive.Call as Call
import qualified Derive.Call.GraceUtil as GraceUtil
import qualified Derive.Call.Make as Make
import qualified Derive.Call.Module as Module
import qualified Derive.Controls as Controls
import qualified Derive.Derive as Derive
import qualified Derive.EnvKey as EnvKey
import qualified Derive.Expr as Expr
import qualified Derive.Instrument.DUtil as DUtil
import qualified Derive.Scale.BaliScales as BaliScales
import qualified Derive.Scale.Selisir as Selisir
import qualified Derive.Scale.Twelve as Twelve
import qualified Derive.Score as Score
import qualified Derive.ShowVal as ShowVal

import qualified Perform.Midi.Control as Control
import qualified Perform.Midi.Patch as Patch
import qualified Perform.NN as NN

import qualified Instrument.InstTypes as InstTypes
import qualified User.Elaforge.Instrument.Kontakt.Gong as Gong
import qualified User.Elaforge.Instrument.Kontakt.KendangBali as KendangBali
import qualified User.Elaforge.Instrument.Kontakt.KendangSunda as KendangSunda
import qualified User.Elaforge.Instrument.Kontakt.Mridangam as Mridangam
import qualified User.Elaforge.Instrument.Kontakt.Pakhawaj as Pakhawaj
import qualified User.Elaforge.Instrument.Kontakt.Reyong as Reyong
import qualified User.Elaforge.Instrument.Kontakt.ScGamelan as ScGamelan
import qualified User.Elaforge.Instrument.Kontakt.Wayang as Wayang
import qualified User.Elaforge.Instrument.Reaktor as Reaktor

import Global


synth :: MidiInst.Synth
synth = MidiInst.synth synth_name "Native Instrument Kontakt" patches

synth_name :: InstTypes.SynthName
synth_name = "kontakt"

patches :: [MidiInst.Patch]
patches =
    MidiInst.default_patch pb_range [] : concat
    [ mine_patches
    , misc_patches
    , hang_patches
    , dio8_patches
    , KendangBali.patches, KendangSunda.patches
    , Mridangam.patches, Pakhawaj.patches, Reyong.patches, Gong.patches
    , ScGamelan.patches
    , Wayang.patches
    ]

patch :: InstTypes.Name -> [(Midi.Control, Score.Control)] -> MidiInst.Patch
patch = MidiInst.named_patch pb_range

-- One pitch bend modulator can only do +-12, but if you put two on you get
-- +-24.
pb_range :: Patch.PbRange
pb_range = (-24, 24)

-- * mine

mine_patches :: [MidiInst.Patch]
mine_patches =
    [ MidiInst.make_patch $ MidiInst.add_flag Patch.ResumePlay $
        Patch.patch pb_range "tambura"
    , set_scale $ MidiInst.make_patch $ Patch.patch pb_range "bali-guitar"
    ]
    where
    set_scale =
        (MidiInst.patch#Patch.defaults#Patch.scale #= Just instrument_scale)
        . MidiInst.default_scale Selisir.scale_id
        . MidiInst.environ EnvKey.tuning tuning
    tuning = BaliScales.Umbang
    instrument_scale =
        Selisir.instrument_scale (take 10 . drop 5) Selisir.laras_rambat tuning

-- * misc

misc_patches :: [MidiInst.Patch]
misc_patches = concat
    [library, mcgill, balalaika, anthology_wind, sonic_couture, misc]

library :: [MidiInst.Patch]
library =
    [ patch "choir" [(1, "vowel")]
    ]

-- | From the McGill sample library.
mcgill :: [MidiInst.Patch]
mcgill =
    [ pressure "viol", pressure "shawm", pressure "crumhorn"
    , plucked "lute"
    ]
    where
    plucked name = patch name []
    pressure name = MidiInst.pressure $
        patch name [(CC.cc14, Controls.lpf), (CC.cc15, Controls.q)]

-- | Ilya Efimov Bailalaika Prima
-- I changed it to support (-24, 24) pb range.
balalaika :: [MidiInst.Patch]
balalaika =
    [ MidiInst.code #= code $
        MidiInst.attribute_map #= Patch.single_keyswitches ks $
        MidiInst.make_patch $
        MidiInst.add_flag Patch.HoldKeyswitch $
        Patch.control_map #= Control.control_map controls $
        Patch.patch pb_range "balalaika"
    ]
    where
    code = MidiInst.note_generators
        [("(", (Articulation.c_attr_slur mempty Attrs.legato))]
    -- g6 strum, a6 solo, b6 harmony
    controls =
        [ (1, "trem-dyn")
        , (2, "trem-speed")
        ]
    ks =
        [ (Attrs.attr "str2", Key.ds4)
        , (Attrs.gliss, Key.c4)
        , (Attrs.legato, Key.as3)
        , (Attrs.vib, Key.d4)
        , (Attrs.harm, Key.gs3)
        , (Attrs.staccato, Key.cs4)
        -- These are just pressed, not held, but hold_keyswitch is
        -- per-patch, not per-keyswitch.
        , (Attrs.trem, Key.a3)
        , (mempty, Key.b3)
        ]

-- | Bela D Anthology Spiritual Wind
-- Change volume to cc 2.
-- Change b3 and c3 to be normal keyswitches instead of toggles.
anthology_wind :: [MidiInst.Patch]
anthology_wind =
    [ MidiInst.pressure $
        MidiInst.attribute_map #= Patch.single_keyswitches dizi_ks $
        patch "dizi" [(CC.mod, Controls.vib)]
    ]
    where
    -- blow and overblow as keyswitches instead of on/off
    dizi_ks =
        [ (mempty, Key2.c2)
        , (ornament <> Attrs.v1, Key2.cs2)
        , (Attrs.staccato, Key2.d2)
        , (ornament <> Attrs.v2, Key2.ds2)
        , (Attrs.staccato <> blow, Key.e2) -- unpitched attack
        , (ornament <> Attrs.v3, Key2.fs2)
        , (ornament <> Attrs.v4, Key2.gs2)
        , (ornament <> Attrs.long <> Attrs.v1, Key2.as2)
        , (blow, Key2.b3) -- sustain with sharp attack
        , (Attrs.accent, Key2.c3) -- like 'blow', but softer attack
        , (ornament <> Attrs.long <> Attrs.v2, Key2.cs3)
        ]
    -- f2 slide 1 up / down
    -- g2 slide 2 up / down
    -- a2 slide 2 down
    ornament = Attrs.attr "o"
    blow = Attrs.attr "blow"

-- * sonic couture

sonic_couture :: [MidiInst.Patch]
sonic_couture =
    [ patch "ebow"
        [(1, "harm"), (21, Controls.lpf), (22, Controls.q), (23, Controls.hpf)]
    , guzheng
    ]

guzheng :: MidiInst.Patch
guzheng = MidiInst.code #= code $ MidiInst.nn_range range $
    MidiInst.decay #= Just 5 $
    MidiInst.attribute_map #= Patch.single_keyswitches ks $
    patch "guzheng" [(23, Controls.lpf), (24, Controls.q), (27, Controls.hpf)]
    where
    code = MidiInst.note_generators [("左", DUtil.attributes_note Attrs.left)]
        <> MidiInst.note_transformers [("standard-strings", standard_strings)]
        <> MidiInst.null_call c_highlight_strings
    standard_strings = DUtil.transformer0 "standard-strings"
        ("Set " <> ShowVal.doc EnvKey.open_strings
            <> " to standard pitches: " <> ShowVal.doc strings)
        $ \_ deriver -> Derive.with_val EnvKey.open_strings
            (map Twelve.nn_pitch strings) deriver
    ks =
        [ (Attrs.harm, Key2.as5)
        , (Attrs.left, Key2.b5) -- left hand, no pick
        , (mempty, Key2.c6) -- right hand, picked
        ]
    strings = take (4*5 + 1) $ -- 4 octaves + 1, so D to D
        concatMap ((\nns oct -> map (oct+) nns) notes) octaves
        where
        notes = [NN.d2, NN.e2, NN.fs2, NN.a2, NN.b2]
        octaves = map fromIntegral [0, 12 ..]
    -- Let's say the top string can bend a minor third.
    range = (head strings, last strings + 3)

c_highlight_strings :: Derive.Generator Derive.Note
c_highlight_strings = Note.transformed_note
    ("Highlight any notes whose initial pitch either is or isn't in "
    <> ShowVal.doc EnvKey.open_strings <> ".") mempty $ \args deriver -> do
        start <- Args.real_start args
        Highlight.out_of_range $
            Highlight.open_strings start Highlight.warn_non_open deriver

-- * hang

hang_patches :: [MidiInst.Patch]
hang_patches = map (MidiInst.code #= hang_code)
    [ MidiInst.attribute_map #= Patch.single_keyswitches hang_ks $
        patch "hang" []
    ]

hang_code :: MidiInst.Code
hang_code =
    MidiInst.note_calls
        [ MidiInst.both call (Make.attributed_note Module.instrument attrs)
        | (attrs, _, Just call, _) <- hang_strokes
        -- Make sure to not shadow the default "" call.
        , call /= ""
        ]
    <> MidiInst.cmd hang_cmd

hang_cmd :: Cmd.M m => Msg.Msg -> m Cmd.Status
hang_cmd = CUtil.keyswitches [(Keymap.physical_key char, text, key)
    | (_, key, Just text, Just char) <- hang_strokes]

-- | The order is important because it determines attr lookup priority.
hang_strokes :: [(Attrs.Attributes, Midi.Key, Maybe Expr.Symbol, Maybe Char)]
hang_strokes =
    [ (Attrs.center,  Key.c2,     Just "",   Just 'Z')
    , (Attrs.edge,    Key.cs2,    Just "旁", Just 'X')
    , (Attrs.slap,    Key.d2,     Just "打", Just 'C')
    , (Attrs.middle,  Key.ds2,    Just "中", Just 'V')
    , (Attrs.knuckle, Key.e2,     Just "指", Just 'B')
    , (mempty,        Key.c2,     Nothing,   Nothing)
    ]

hang_ks :: [(Attrs.Attributes, Midi.Key)]
hang_ks = [(attrs, key) | (attrs, key, _, _) <- hang_strokes]

-- * 8 dio

dio8_patches :: [MidiInst.Patch]
dio8_patches =
    [ MidiInst.code #= pedal_down $
        MidiInst.attribute_map #= santur_ks $ patch "santur" []
    , MidiInst.code #= (qanun_calls <> pedal_down) $
        MidiInst.attribute_map #= qanun_ks $ patch "qanun" []
    ]
    where
    santur_ks = ks_from Key2.c_1 $
        [ (m <> art)
        -- wood-m is the default
        | m <- [mempty, Attrs.attr "soft-m", Attrs.attr "softest-m"]
        -- sustain is the default
        , art <- [mempty, Attrs.attr "half-mute", Attrs.mute]
        ] ++ [Attrs.attr "sfx"]
    qanun_ks = ks_from Key2.d_2 $ concat
        [ [mempty] -- thumb
        , map Attrs.attr ["fingertip", "pick", "pick-bridge", "pizz"]
        , map fst grace_intervals
        , [ Attrs.trem, Attrs.attr "vib-peg", Attrs.harm, Attrs.attr "fiske"
          , Attrs.attr "sfx"
          ]
        ]
    ks_from key attrs = Patch.single_keyswitches $ zip attrs [key..]
    pedal_down = MidiInst.postproc $
        DUtil.default_controls [(Controls.pedal, 1)]
    qanun_calls = MidiInst.note_calls
        [ MidiInst.generator "g" $
            Make.modify_generator_
                "Multiply %dyn by .65, since the grace samples are too loud."
                (Call.multiply_dynamic 0.65) $
            GraceUtil.c_attr_grace $ Map.fromList $
            map Tuple.swap grace_intervals
        , MidiInst.both "o" $
            Make.modify_calls_ "" (Call.add_constant Controls.octave (-1))
                Articulation.c_harmonic
        ]
    grace_intervals =
        [ (grace <> dir <> interval, step * sign)
        | (interval, step) <- zip [Attrs.half, Attrs.whole] [1..]
        , (dir, sign) <- [(Attrs.up, 1), (Attrs.down, -1)]
        ]
    grace = Attrs.attr "grace"


-- * misc

misc :: [MidiInst.Patch]
misc = [MidiInst.code #= Reaktor.resonant_filter $ patch "filtered" []]
