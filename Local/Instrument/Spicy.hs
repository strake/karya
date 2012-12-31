-- | Spicy guitar, free at http://www.spicyguitar.com/
module Local.Instrument.Spicy where
import Util.Control
import qualified Util.Seq as Seq
import qualified Midi.Key as Key
import qualified Midi.Midi as Midi
import qualified Derive.Attrs as Attrs
import qualified Derive.Call.Note as Note
import qualified Derive.Call.Util as Util
import qualified Derive.Derive as Derive
import qualified Derive.Score as Score

import qualified Perform.Midi.Instrument as Instrument
import qualified App.MidiInst as MidiInst


load :: FilePath -> IO [MidiInst.SynthDesc]
load _dir = return $ MidiInst.make $
    (MidiInst.softsynth synth_name pb_range controls)
        { MidiInst.modify_wildcard =
            (Instrument.instrument_#Instrument.hold_keyswitch #= True)
            . Instrument.set_keyswitches keyswitches
        , MidiInst.code = MidiInst.null_call note_call
        }

synth_name :: String
synth_name = "spicy"

pb_range = (-3, 3)

-- | WARNING: changing these while playing tends to crash the VST.
controls :: [(Midi.Control, String)]
controls =
    [ (20, "position") -- 0 for bridge, 1 for middle
    , (21, "finger") -- 0 for finger plucking, 1 for pick
    , (22, "inharmonicity")
    , (23, "twang")
    , (24, "color")
    , (25, "impedance")
    , (26, "vibrato") -- speed of vibrato
    , (27, "mute") -- amount of palm mute effect
    , (28, "harmonic")
    ]

keyswitches :: [(Score.Attributes, Midi.Key)]
keyswitches =
    [ (Attrs.legato, Key.b2)
    , (Attrs.mute, Key.c3)
    , (Attrs.harmonic, Key.cs3)
    ]

note_call :: Derive.NoteCall
note_call = Note.transformed_note
    ("If given a string-name attribute in " <> attrs <> ", suffix the"
        <> " instrument with the string name.  When combined with the proper"
        <> " midi config, this will redirect the note to the proper channel"
        <> " for that string.")
    transform
    where
    attrs = Seq.join ", " ["`" <> a <> "`" | a <- strings]
    transform deriver = do
        attrs <- Util.get_attrs
        inst <- Util.lookup_instrument
        let string = Seq.head
                [string | attr <- Score.attrs_list attrs, string <- strings,
                    attr == string]
        case (inst, string) of
            (Just inst, Just string) ->
                Derive.with_instrument (string_inst inst string) deriver
            _ -> deriver
    string_inst inst string =
        Score.Instrument $ Score.inst_name inst ++ "-" ++ string

strings :: [String]
strings = ["e1", "a", "d", "g", "b", "e2"]

-- | Create the proper midi config to work with the string attrs used by
-- 'note_call'.
midi_config :: String -> Instrument.InstrumentName -> Instrument.Config
midi_config dev_name name = Instrument.config $
    inst name 0 : [inst (name ++ "-" ++ string) chan
        | (string, chan) <- zip strings [1..]]
    where
    inst name chan = (Score.instrument synth_name name, [(dev, chan)])
    dev = Midi.write_device dev_name
