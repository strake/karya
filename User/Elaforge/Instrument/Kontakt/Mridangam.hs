-- Copyright 2015 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Mridangam patch.
module User.Elaforge.Instrument.Kontakt.Mridangam where
import qualified Data.Char as Char
import qualified Data.Map as Map
import qualified Data.Text as Text

import qualified Midi.Key as Key
import qualified Midi.Key2 as Key2
import qualified Midi.Midi as Midi

import qualified Cmd.Instrument.CUtil as CUtil
import qualified Cmd.Instrument.Drums as Drums
import qualified Cmd.Instrument.MidiInst as MidiInst

import qualified Derive.Attrs as Attrs
import qualified Derive.Call.Make as Make
import qualified Derive.Call.Module as Module
import qualified Derive.Expr as Expr
import qualified Derive.Instrument.DUtil as DUtil
import qualified Derive.PSignal as PSignal

import qualified Perform.NN as NN
import qualified Perform.Pitch as Pitch
import qualified User.Elaforge.Instrument.Kontakt.Util as Util
import Global


patches :: [MidiInst.Patch]
patches =
    [ code NN.d4 $ patch "mridangam-d" notes_d
    , code NN.g4 $ patch "mridangam-g" notes_g
    , code NN.g4 $ patch "mridangam-old" pitched_notes_old
    ]
    where
    patch name notes = CUtil.pitched_drum_patch notes $
        MidiInst.named_patch (-24, 24) name []
    code natural_nn = MidiInst.code
        #= make_code pitched_strokes natural_nn all_notes both_calls

make_code :: [Attrs.Attributes] -> Pitch.NoteNumber -> [Drums.Note]
    -> [(Expr.Symbol, [Expr.Symbol], Maybe Char)] -> MidiInst.Code
make_code pitched_strokes natural_nn notes both = mconcat
    [ MidiInst.note_generators generators
    , MidiInst.val_calls vals
    , MidiInst.cmd (CUtil.insert_call char_to_call)
    ]
    where
    generators = concat
        [ CUtil.drum_calls (Just (pitched_strokes, natural_nn)) Nothing notes
        , DUtil.multiple_calls [(call, subcalls) | (call, subcalls, _) <- both]
        ]
    vals =
        [ ("natural", Make.constant_val Module.instrument "natural"
            doc (PSignal.nn_pitch natural_nn))
        ]
        where doc = "Emit the drum's recorded pitch. Use like `#=(natural)`."
    char_to_call = Map.fromList $ concat
        [ [(Drums.note_char n, Drums.note_name n) | n <- notes]
        , [(char, call) | (call, _, Just char) <- both]
        ]

-- | Single symbols for two strokes together.  thom+x becomes a capital X,
-- and there are a few ad-hoc capital letters for more common tha+x
-- combinations.
both_calls :: [(Expr.Symbol, [Expr.Symbol], Maybe Char)]
both_calls = make_both left_notes right_notes special_names
    [ ("N", 'g'), ("D", 'b')
    , ("K", 'h'), ("T", 'n')
    , ("P", 'j'), ("X", 'm')
    ]
    where
    special_names = [("P", ["+", "k"]), ("X", ["+", "t"])]
        ++ [(sym c, ["o", sym (Char.toLower c)]) | c <- "KTNDUVI"]
    sym = Expr.Symbol . Text.singleton

-- | Create calls for all simultaneous left and right hand combinations, and
-- key bindings for a few common ones.
make_both :: [Drums.Note] -> [Drums.Note]
    -> [(Expr.Symbol, [Expr.Symbol])] -- ^ special names for pairs
    -> [(Expr.Symbol, Char)] -> [(Expr.Symbol, [Expr.Symbol], Maybe Char)]
make_both left right special_names keys =
    [ (call, subcalls, lookup call keys)
    | (call, subcalls) <- special_names ++ pairs
    ]
    where
    pairs =
        [ (Expr.Symbol $ u rcall <> u lcall, [rcall, lcall])
        | lcall <- map Drums.note_name left
        , rcall <- map Drums.note_name right
        , Text.length (u lcall) == 1 && Text.length (u rcall) == 1
        ]
    u = Expr.unsym

-- | The convention is symbols for thoppi, and letters for valantalai.  Also,
-- vowels for open sounds, consonants for closed ones.  Soft strokes look like
-- a simpler version of their equivalent loud strokes.
left_notes, right_notes :: [Drums.Note]
stops :: [(Drums.Group, [Drums.Group])]
(left_notes, right_notes, stops) = (left_notes, right_notes, stops)
    where
    left_notes = concat
        [ group t_closed
            [ n 'a' "-" tha 0.5
            , n 'z' "+" tha 1
            ]
        , group t_open
            [ n 's' "." thom 0.5
            , n 'x' "o" thom 1
            , n 'd' "._" gumki 0.5
            , n 'c' "o_" gumki 1
            , n 'f' "o-" (gumki <> Attrs.medium) 1
            , n 'g' "o^" (gumki <> Attrs.high) 1
            , n 'v' "o/" (gumki <> Attrs.up) 1
            -- TODO when I can play it, have 'o 0' to 'o 1' for pitch.  Then
            -- o- is the same as 'o 0'.  Maybe it should be called o0 then?
            -- But it might also be more useful to have generic low, medium,
            -- high.  Or o_ o- o^
            , n 'b' "*" (thom <> dry) 1
            ]
        ]
    right_notes = concat
        [ group v_closed
            [ n '1' "l" ki 0.5
            , n 'q' "k" ki 1
            , n 'w' "t" ta 1
            ]
        , group v_sadam
            [ n 'e' "n" nam 1
            , n 'r' "d" din 1
            , n '7' "," (meetu <> ki) 1
            , n 'u' "^" (meetu <> ta) 1
            ]
        , group v_chapu
            [ n '5' "v" muruchapu 1
            , n 't' "u" araichapu 1
            ]
        , group v_dheem [n 'y' "i" dheem 1]
        ]

    stops =
        [ (t_closed, [t_open])
        , (v_closed, [v_sadam, v_chapu, v_dheem])
        , (v_sadam, [v_chapu, v_dheem])
        , (v_chapu, [v_dheem])
        ]
    v_closed = "v-closed"
    v_sadam = "v-sadam"
    v_chapu = "v-chapu"
    v_dheem = "v-dheem"
    t_closed = "t-closed"
    t_open = "t-open"
    group name = map $ \n -> n { Drums.note_group = name }
    n = Drums.note_dyn

pitched_strokes :: [Attrs.Attributes]
pitched_strokes =
    [ thom, gumki
    , nam, din
    , meetu <> ki, meetu <> ta
    , muruchapu, araichapu
    , dheem
    ]

all_notes :: [Drums.Note]
all_notes = left_notes ++ right_notes

notes_d, notes_g :: CUtil.PitchedNotes
(notes_d, _unmapped_notes_d) = make_notes Key.gs3
(notes_g, _unmapped_notes_g) = make_notes Key.d4
    -- The given pitch is the natural pitch of the instrument.  The root note is
    -- the bottom of the pitch range.

make_notes :: Midi.Key
    -> (CUtil.PitchedNotes, ([Drums.Note], [Attrs.Attributes]))
make_notes root_nn = CUtil.drum_pitched_notes all_notes $
    CUtil.make_cc_keymap Key2.c_1 12 root_nn
        [ [tha]
        , [thom, gumki, gumki <> Attrs.up, thom <> dry]
        , [ki]
        , [ta]
        , [nam]
        , [din]
        , [araichapu, muruchapu]
        , [meetu <> ki, dheem]
        , [meetu <> ta]
        ]

write_ksp :: IO ()
write_ksp = mapM_ (uncurry Util.write)
    -- Util.drum_mute_ksp ignores the root pitch so I don't need to worry about
    -- 'notes_g'.
    [ ("mridangam.ksp.txt", Util.drum_mute_ksp "mridangam" notes_d stops)
    , ("mridangam-old.ksp.txt", Util.drum_mute_ksp "mridangam"
        pitched_notes_old stops)
    ]

pitched_notes_old :: CUtil.PitchedNotes
(pitched_notes_old, _pitched_notes_old) =
    CUtil.drum_pitched_notes all_notes $ Map.fromList $ map make
    -- left
    [ (tha, (Key.g_1, Key.e0))
    , (thom, (Key.g0, Key.e1))
    , (thom <> Attrs.staccato, (Key.g1, Key.e2))
    -- right
    , (ki, (Key.g2, Key.e3))
    , (ta, (Key.g3, Key.e4))
    , (nam, (Key.g4, Key.e5))
    , (din, (Key.g5, Key.e6))
    , (din <> Attrs.v2, (Key.g6, Key.e7))
    , (dheem, (Key.g7, Key.e8))
    , (araichapu, (Key.g8, Key.e9))
    , (muruchapu, (Key.g9, Key.g9))
    ]
    where make (attrs, (low, high)) = (attrs, ([], low, high, Key.e4))

-- * attrs

tha = Attrs.attr "tha"
thom = Attrs.attr "thom"
ki = Attrs.attr "ki"
ta = Attrs.attr "ta"
nam = Attrs.attr "nam"
din = Attrs.attr "din"
dheem = Attrs.attr "dheem"
araichapu = Attrs.attr "araichapu"
muruchapu = Attrs.attr "muruchapu"
meetu = Attrs.attr "meetu"

gumki = Attrs.attr "gumki"
-- Without ravai.
dry = Attrs.attr "dry"
