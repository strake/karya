-- Copyright 2015 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Calls to deal with an entire ensemble, or miscellaneous instruments.
module Derive.Call.Bali.Gong where
import qualified Util.Debug as Debug
import qualified Derive.Args as Args
import qualified Derive.Call as Call
import qualified Derive.Call.Module as Module
import qualified Derive.Call.Sub as Sub
import qualified Derive.Call.Tags as Tags
import qualified Derive.Derive as Derive
import qualified Derive.Flags as Flags
import qualified Derive.Scale as Scale
import qualified Derive.Scale.BaliScales as BaliScales
import qualified Derive.Scale.Legong as Legong
import qualified Derive.Score as Score
import qualified Derive.Sig as Sig

import qualified Perform.Pitch as Pitch
import Global
import Types


module_ :: Module.Module
module_ = "bali" <> "gong"

note_calls :: Derive.CallMaps Derive.Note
note_calls = Derive.transformer_call_map
    [ ("pokok", c_pokok)
    , ("J", c_jegog)
    , ("C", c_calung)
    ]

c_pokok :: Derive.Transformer Derive.Note
c_pokok = Derive.transformer module_ "pokok" (Tags.inst <> Tags.under_invert)
    "Add a pokok note with 'Derive.Flags.infer_duration' and the same pitch,\
    \ transposed into the appropriate range."
    $ Sig.callt ((,,)
    <$> Sig.defaulted "octave" Call.Down
        "Which to choose if the pitch exists in multiple octaves."
    <*> Sig.required_environ "insts" Sig.Prefixed "Instruments."
    <*> range_env
    ) $ \(octave, insts, range) -> Sub.under_invert $ \args deriver -> do
        note <- pokok (Args.start args) octave insts range
        deriver <> note

pokok :: ScoreTime -> Call.UpDown -> [Score.Instrument] -> Scale.Range
    -> Derive.Deriver Derive.NoteDeriver
pokok start octave insts range = do
    (parse_pitch, show_pitch, _) <- Call.get_pitch_functions
    Debug.tracepM "pitch" start
    psig <- Derive.get_pitch Score.default_pitch
    Debug.tracepM "psig" psig
    from_pitch <- Call.get_parsed_pitch parse_pitch =<< Derive.real start
    to_note <- Derive.require ("can't show pitch: " <> showt from_pitch) $
        show_pitch (restrict range octave from_pitch)
    return $ realize_note start insts to_note

-- How to choose high and low ding?
-- I should infer it based on the octave of the melody, but also be able to
-- override easily.  But to know the octave of the melody I need the melody
-- itself along with its range, which is not actually written anywhere or
-- even well defined.  So choose low and do manual for now.

-- | Transpose the pitch by octaves until it fits in the range.
-- Assumes the range is at least one octave, and less than two.
restrict :: Scale.Range -> Call.UpDown -> Pitch.Pitch -> Pitch.Pitch
restrict range octave pitch
    | Scale.in_range range pitch = pitch
    | otherwise = case octave of
        Call.Down
            | with_oct (oct_of bottom) < bottom -> with_oct (oct_of bottom + 1)
            | otherwise -> with_oct (oct_of bottom)
            where bottom = Scale.range_bottom range
        Call.Up
            | with_oct (oct_of top) > top -> with_oct (oct_of top - 1)
            | otherwise -> with_oct (oct_of top)
            where top = Scale.range_top range
    where
    with_oct oct = pitch { Pitch.pitch_octave = oct }
    oct_of = Pitch.pitch_octave

realize_note :: ScoreTime -> [Score.Instrument] -> Pitch.Note
    -> Derive.NoteDeriver
realize_note start instruments note =
    Call.add_flags Flags.infer_duration $
        mconcatMap (\inst -> Derive.with_instrument inst realize1) instruments
    where
    realize1 = Derive.at start $ Call.pitched_note =<< Call.eval_note start note

range_env :: Sig.Parser Scale.Range
range_env = Scale.Range
    <$> Sig.required_environ "bottom" Sig.Prefixed "Bottom of the range."
    <*> Sig.required_environ "top" Sig.Prefixed "Top of the range."

make_pokok :: Text -> Scale.Range -> [Score.Instrument]
    -> Derive.Transformer Derive.Note
make_pokok name range default_insts = Derive.transformer module_ name
    (Tags.inst <> Tags.under_invert)
    ("Add a " <> name <> " note with 'Derive.Flags.infer_duration' and the\
    \ same pitch, transposed into the " <> name <> " range.")
    $ Sig.callt ((,)
    <$> Sig.defaulted "octave" Call.Down
        "If the pitch exists in multiple octaves, choose this one."
    <*> Sig.environ "insts" Sig.Prefixed default_insts "Instruments."
    ) $ \(octave, insts) -> Sub.under_invert $ \args deriver -> do
        note <- pokok (Args.start args) octave insts range
        deriver <> note

c_jegog :: Derive.Transformer Derive.Note
c_jegog = make_pokok "jegog" (BaliScales.scale_range Legong.jegog)
    [Score.Instrument "jegog-p", Score.Instrument "jegog-s"]

c_calung :: Derive.Transformer Derive.Note
c_calung = make_pokok "calung" (BaliScales.scale_range Legong.calung)
    [Score.Instrument "calung-p", Score.Instrument "calung-s"]