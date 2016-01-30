-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Instrument.MidiDb_test where
import qualified Data.Map as Map

import Util.Test
import qualified Midi.Midi as Midi
import qualified Derive.Score as Score
import qualified Perform.Midi.Instrument as Instrument
import qualified Instrument.MidiDb as MidiDb
import qualified Local.Instrument.Kontakt as Kontakt
import Global


test_lookup_midi = do
    Just synth <- Kontakt.load ""
    let midi_db = fst $ MidiDb.midi_db [synth]
    let f inst = MidiDb.lookup_midi midi_db (Score.Instrument inst)

    let kontakt_inst name = (Instrument.instrument Kontakt.pb_range name [])
            { Instrument.inst_score = Score.Instrument ("kontakt/" <> name)
            , Instrument.inst_synth = "kontakt"
            }
        hang = kontakt_inst "hang"
    equal (f "kontakt/hang") (Just hang)
    -- Has default inst.
    equal (f "kontakt/") $ Just (kontakt_inst "")

test_verify_patches = do
    let f = first extract . MidiDb.verify_patches . mkpatches
        extract = map (second name) . Map.toList
        name = Instrument.inst_name . Instrument.patch_instrument . fst
    -- different initialization gets split
    equal (f [("a", pgm_change 1), ("*a", pgm_change 2)])
        ([("a1", "a"), ("a2", "*a")],
            ["split into a1, a2: a (a.vc), *a (*a.vc)"])

    equal (f [("a", pgm_change 1), ("*a", pgm_change 1)])
        ([("a", "a")], ["dropped patches with the same initialization as "
            <> "a (a.vc): *a (*a.vc)"])
    -- no dropping needed if the names are different
    equal (f [("a", pgm_change 1), ("b", pgm_change 1)])
        ([("a", "a"), ("b", "b")], [])

mkpatches ps = map (uncurry mkpatch) ps

mkpatch :: Instrument.InstrumentName -> Instrument.InitializePatch
    -> MidiDb.PatchCode ()
mkpatch name init = (patch, ())
    where
    inst = Instrument.instrument (-2, 2) name []
    patch = (Instrument.patch inst)
        { Instrument.patch_initialize = init
        , Instrument.patch_file = "path/" ++ untxt name ++ ".vc"
        }

pgm_change :: Midi.Program -> Instrument.InitializePatch
pgm_change pgm = Instrument.InitializeMidi $ map (Midi.ChannelMessage 0) $
    Midi.program_change 0 pgm
