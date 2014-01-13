-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Utilities for simple scales, which simply map pitch names to frequencies.
-- Ok, so they also have octave structure, used by the input mechanism and to
-- parse to 'Pitch.Pitch'es, but it can be ignored (or set to the number of
-- degrees in the scale) if you really don't want octaves.
module Derive.Scale.Scales where
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as Text

import Util.Control
import qualified Util.Map as Map
import qualified Util.Num as Num
import qualified Util.Pretty as Pretty

import qualified Derive.Call as Call
import qualified Derive.Call.ScaleDegree as ScaleDegree
import qualified Derive.Controls as Controls
import qualified Derive.Derive as Derive
import qualified Derive.Deriver.Internal as Internal
import qualified Derive.Environ as Environ
import qualified Derive.PitchSignal as PitchSignal
import qualified Derive.Scale as Scale
import qualified Derive.Scale.Theory as Theory
import qualified Derive.Score as Score
import qualified Derive.ShowVal as ShowVal
import qualified Derive.TrackLang as TrackLang

import qualified Perform.Pitch as Pitch
import qualified Perform.Signal as Signal
import Types


-- | Make a simple scale where there is a direct mapping from input to note to
-- nn.
make_scale :: DegreeMap -> Pitch.ScaleId -> Text -> Text -> Scale.Scale
make_scale dmap scale_id pattern doc = Scale.Scale
    { Scale.scale_id = scale_id
    , Scale.scale_pattern = pattern
    , Scale.scale_symbols = []
    , Scale.scale_transposers = standard_transposers
    , Scale.scale_read = const $ read_note dmap
    , Scale.scale_show = const $ show_pitch dmap
    , Scale.scale_layout =
        Scale.diatonic_layout (fromIntegral (dm_per_octave dmap))
    , Scale.scale_transpose = transpose dmap
    , Scale.scale_enharmonics = no_enharmonics
    , Scale.scale_note_to_call = mapped_note_to_call dmap scale
    , Scale.scale_input_to_note = input_to_note dmap
    , Scale.scale_input_to_nn = mapped_input_to_nn dmap
    , Scale.scale_call_doc = call_doc standard_transposers dmap doc
    }
    where scale = PitchSignal.Scale scale_id standard_transposers

-- * types

data DegreeMap = DegreeMap {
    dm_to_pitch :: Map.Map Pitch.Note Pitch.Pitch
    , dm_to_note :: Map.Map Pitch.Pitch Pitch.Note
    , dm_to_nn :: Map.Map Pitch.Pitch Pitch.NoteNumber
    -- | Number of scale steps per octave.  Actually, simple scales are just
    -- a collection of frequencies and don't need to have a notion of an
    -- octave.  But since the input mechanism wants to orient around octaves,
    -- it needs to know how many keys to assign to each octave.  So if your
    -- scale has no octaves, then just set this to 7, that way it lines up with
    -- the piano keyboard.
    , dm_per_octave :: Pitch.PitchClass
    }

instance Pretty.Pretty DegreeMap where
    format dmap = Pretty.format $ Map.fromList $ do
        (note, degree) <- Map.toList (dm_to_pitch dmap)
        let nn = Map.lookup degree (dm_to_nn dmap)
        return (degree, (note, nn))

degree_map :: Pitch.PitchClass
    -> Pitch.Octave -- ^ The first Note is this Octave and PitchClass.
    -> Pitch.PitchClass
    -> [Pitch.Note] -> [Pitch.NoteNumber] -> DegreeMap
degree_map per_octave start_octave start_pc notes_ nns_ = DegreeMap
    { dm_to_pitch = Map.fromList (zip notes pitches)
    , dm_to_note = Map.fromList (zip pitches notes)
    , dm_to_nn = Map.fromList (zip pitches nns)
    , dm_per_octave = per_octave
    }
    where
    pitches = pitches_from per_octave start_octave start_pc
    -- Guard against an infinite notes or nns.
    (notes, nns) = unzip $ zip notes_ nns_

pitches_from :: Pitch.PitchClass -> Pitch.Octave -> Pitch.PitchClass
    -> [Pitch.Pitch]
pitches_from per_octave start_octave start_pc = drop start_pc
    [Pitch.Pitch oct (Pitch.Degree pc 0) | oct <- [start_octave..],
        pc <- [0..per_octave-1]]

type PitchToNoteNumber = PitchSignal.PitchConfig -> Pitch.Pitch
    -> Either Scale.ScaleError Pitch.NoteNumber

-- * scale functions

read_note :: DegreeMap -> Pitch.Note -> Either Scale.ScaleError Pitch.Pitch
read_note dmap note = maybe (Left Scale.UnparseableNote) Right $
    Map.lookup note (dm_to_pitch dmap)

show_pitch :: DegreeMap -> Pitch.Pitch -> Either Scale.ScaleError Pitch.Note
show_pitch dmap pitch = maybe (Left Scale.UnparseableNote) Right $
    Map.lookup pitch (dm_to_note dmap)

-- ** transpose

transpose :: DegreeMap -> Derive.Transpose
transpose dmap _transposition _key steps pitch
    | Map.member result (dm_to_note dmap) = Right result
    | otherwise = Left Scale.InvalidTransposition
    where result = add_pc dmap steps pitch

-- | Transpose function for a non-transposing scale.
non_transposing :: Derive.Transpose
non_transposing _ _ _ _ = Left Scale.InvalidTransposition

standard_transposers :: Set.Set Score.Control
standard_transposers = Set.fromList
    [Controls.chromatic, Controls.diatonic, Controls.nn, Controls.hz]

-- ** note_to_call

-- | A specialization of 'note_to_call' that operates on scales with
-- a ScaleMap, i.e. a static map from notes to degrees, and from degrees to
-- NNs.
mapped_note_to_call :: DegreeMap -> PitchSignal.Scale
    -> Pitch.Note -> Maybe Derive.ValCall
mapped_note_to_call dmap scale = note_to_call scale dmap to_nn
    where
    to_nn _config pitch =
        maybe (Left Scale.InvalidTransposition) Right $
            Map.lookup pitch (dm_to_nn dmap)

-- | Create a note call that respects chromatic and diatonic transposition.
-- However, diatonic transposition is mapped to chromatic transposition,
-- so this is for scales that don't distinguish.
note_to_call :: PitchSignal.Scale -> DegreeMap -> PitchToNoteNumber
    -> Pitch.Note -> Maybe Derive.ValCall
note_to_call scale dmap pitch_to_nn note =
    case Map.lookup note (dm_to_pitch dmap) of
        Nothing -> Nothing
        Just pitch -> Just $ ScaleDegree.scale_degree scale
            (pitch_nn pitch) (pitch_note pitch)
    where
    pitch_nn :: Pitch.Pitch -> Scale.PitchNn
    pitch_nn pitch config =
        scale_to_pitch_error diatonic chromatic $
            to_note (add_pc dmap steps pitch) frac config
        where
        (steps, frac) = properFraction (chromatic + diatonic)
        controls = PitchSignal.pitch_controls config
        chromatic = Map.findWithDefault 0 Controls.chromatic controls
        diatonic = Map.findWithDefault 0 Controls.diatonic controls
    to_note pitch frac config
        | frac == 0 = to_nn pitch
        | otherwise = Num.scale
            <$> to_nn pitch
            <*> to_nn (add_pc dmap 1 pitch)
            <*> return (Pitch.NoteNumber frac)
        where
        to_nn = pitch_to_nn config

    pitch_note :: Pitch.Pitch -> Scale.PitchNote
    pitch_note pitch config =
        maybe (Left err) Right $ Map.lookup transposed (dm_to_note dmap)
        where
        err = invalid_transposition diatonic chromatic
        transposed = add_pc dmap (floor (chromatic + diatonic)) pitch
        chromatic = Map.findWithDefault 0 Controls.chromatic controls
        diatonic = Map.findWithDefault 0 Controls.diatonic controls
        controls = PitchSignal.pitch_controls config

add_pc :: DegreeMap -> Pitch.PitchClass -> Pitch.Pitch -> Pitch.Pitch
add_pc dmap = Pitch.add_pc (dm_per_octave dmap)

lookup_key :: TrackLang.Environ -> Maybe Pitch.Key
lookup_key = fmap Pitch.Key . TrackLang.maybe_val Environ.key

scale_to_pitch_error :: Signal.Y -> Signal.Y
    -> Either Scale.ScaleError a -> Either PitchSignal.PitchError a
scale_to_pitch_error diatonic chromatic = either (Left . msg) Right
    where
    msg err = case err of
        Scale.InvalidTransposition -> invalid_transposition diatonic chromatic
        Scale.KeyNeeded -> PitchSignal.PitchError
            "no key is set, but this transposition needs one"
        Scale.UnparseableEnviron name val -> PitchSignal.PitchError $
            txt (Pretty.pretty name) <> " unparseable by given scale: " <> val
        Scale.UnparseableNote -> PitchSignal.PitchError
            "unparseable note (shouldn't happen)"

invalid_transposition :: Signal.Y -> Signal.Y -> PitchSignal.PitchError
invalid_transposition diatonic chromatic =
    PitchSignal.PitchError $ "note can't be transposed: "
        <> Text.unwords (filter (not . Text.null)
            [fmt "d" diatonic, fmt "c" chromatic])
    where
    fmt _ 0 = ""
    fmt code val = txt (Pretty.pretty val) <> code

-- ** input

type InputToNote = Maybe Pitch.Key -> Pitch.Input -> Maybe Pitch.Note

-- | Input to note for simple scales without keys.
input_to_note :: DegreeMap -> InputToNote
input_to_note dmap _key (Pitch.Input kbd pitch frac) = do
    pitch <- simple_kbd_to_scale dmap kbd pitch
    note <- Map.lookup pitch (dm_to_note dmap)
    return $ ScaleDegree.pitch_expr frac note

-- | Input to NoteNumber for scales that have a direct relationship between
-- Degree and NoteNumber.
mapped_input_to_nn :: DegreeMap
    -> (ScoreTime -> Pitch.Input -> Derive.Deriver (Maybe Pitch.NoteNumber))
mapped_input_to_nn dmap = \_pos (Pitch.Input kbd pitch frac) -> return $ do
    pitch <- simple_kbd_to_scale dmap kbd pitch
    to_nn pitch frac
    where
    to_nn pitch frac
        | frac == 0 = lookup pitch
        | frac > 0 = do
            nn <- lookup pitch
            next <- lookup (add_pc dmap 1 pitch)
            return $ Num.scale nn next (Pitch.NoteNumber frac)
        | otherwise = do
            nn <- lookup pitch
            prev <- lookup (add_pc dmap (-1) pitch)
            return $ Num.scale prev nn (Pitch.NoteNumber (frac + 1))
    lookup d = Map.lookup d (dm_to_nn dmap)

set_direct_input_to_nn :: Scale.Scale -> Scale.Scale
set_direct_input_to_nn scale = scale
    { Scale.scale_input_to_nn = direct_input_to_nn }

-- | An Input maps directly to a NoteNumber.  This is an efficient
-- implementation for scales tuned to 12TET.
direct_input_to_nn :: ScoreTime -> Pitch.Input
    -> Derive.Deriver (Maybe Pitch.NoteNumber)
direct_input_to_nn _pos (Pitch.Input _ pitch frac) =
    return $ Just $ nn + Pitch.nn frac
    where
    nn = fromIntegral $ Theory.semis_to_nn $
        Theory.pitch_to_semis Theory.piano_layout pitch

-- | Convert input to nn by going through note_to_call.  This works for
-- complicated scales that retune based on the environment but is more work.
computed_input_to_nn :: InputToNote -> (Pitch.Note -> Maybe Derive.ValCall)
    -> ScoreTime -> Pitch.Input -> Derive.Deriver (Maybe Pitch.NoteNumber)
computed_input_to_nn input_to_note note_to_call pos input
    | Just note <- input_to_note Nothing input, Just call <- note_to_call note =
        Call.apply_pitch pos call >>= \val -> case val of
            TrackLang.VPitch pitch -> do
                controls <- Derive.controls_at =<< Derive.real pos
                environ <- Internal.get_environ
                return $ either (const Nothing) Just $
                    PitchSignal.eval_pitch pitch
                        (PitchSignal.PitchConfig environ controls)
            _ -> return Nothing
    | otherwise = return Nothing

make_nn :: Maybe Pitch.NoteNumber -> Pitch.NoteNumber -> Maybe Pitch.NoteNumber
    -> Pitch.Frac -> Maybe Pitch.NoteNumber
make_nn mprev nn mnext frac
    | frac == 0 = Just nn
    | frac > 0 = fmap (\next -> interpolate nn next) mnext
    | otherwise = fmap (\prev -> interpolate prev nn) mprev
    where
    interpolate low high = Num.scale low high (Pitch.NoteNumber frac)

-- *** diatonic

simple_kbd_to_scale :: DegreeMap -> Pitch.KbdType -> Pitch.Pitch
    -> Maybe Pitch.Pitch
simple_kbd_to_scale dmap kbd =
    kbd_to_scale kbd (fromIntegral (dm_per_octave dmap)) 0

-- | Convert an absolute Pitch in the input keyboard's layout to a relative
-- Pitch within a scale with the given number of diatonic steps per octave, or
-- Nothing if that key should have no pitch.
kbd_to_scale :: Pitch.KbdType -> Pitch.PitchClass -> Pitch.PitchClass
    -> Pitch.Pitch -> Maybe Pitch.Pitch
kbd_to_scale kbd pc_per_octave tonic pitch = case kbd of
    Pitch.PianoKbd -> piano_kbd_pitch tonic pc_per_octave pitch
    Pitch.AsciiKbd -> Just $ ascii_kbd_pitch pc_per_octave pitch

-- Scale octave doesn't match the kbd octave, but is absolute:
--
--    C D E F G A B|C D E F G A B
-- C  1 2 3 4 5 - - 1 2 3 4 5 - -
-- D  - 1 2 3 4 5 - - 1 2 3 4 5 -
-- E  - - 1 2 3 4 5 - - 1 2 3 4 5
--
-- Piano:
--    0 1 2 3 4 5 6 0 1 2 3 4 5 6 0
--    C D E F G A B|C D E F G A B|C
--    0 1 2 3 4 - - 0
--    0 1 2 3 4 5 6 7 8 - - - - - 0

-- | The MIDI kbd is absolute.  This means that relative scales start on
-- different keys rather than all starting on C.  For example, in C major
-- C produces the first scale degree, while in D major D produces the first
-- scale degree.
--
-- In addition, if the scale octave is not an even multiple of the kbd octave
-- (7), the extra notes produce Nothing.  This check has to be done to
-- the relative PitchClass.  That way, a D on a 6 note scale starting on D is
-- 1, and a C is Nothing.  Thus, the returned Pitch is relative to the given
-- tonic, so it should be formatted as-is, without the key.
piano_kbd_pitch :: Pitch.PitchClass -> Pitch.PitchClass -> Pitch.Pitch
    -> Maybe Pitch.Pitch
piano_kbd_pitch tonic pc_per_octave (Pitch.Pitch oct (Pitch.Degree pc accs))
    | relative_pc >= pc_per_octave = Nothing
    | otherwise =
        Just $ Pitch.Pitch (oct1 + oct_diff) (Pitch.Degree relative_pc accs)
    where
    (oct1, pc1) = adjust_octave pc_per_octave 7 oct pc
    (oct_diff, relative_pc) = (pc1 - tonic) `divMod` max_pc
    max_pc = ceiling (fromIntegral pc_per_octave / 7) * 7

-- | The ASCII kbd is relative.  This means that relative scales always start
-- on \"C\".  So the tonic note of a key in a relative scale is irrelevant,
-- C major and D major both start in the same place.  Of course, they produce
-- different frequencies, but that's the responsibility of
-- 'Scale.scale_note_to_call'.
--
-- Unlike 'absolute_to_pitch', if the scale octave is not an even multiple of
-- the kbd octave (10), the extra notes wrap to the next highest octave.
ascii_kbd_pitch :: Pitch.PitchClass -> Pitch.Pitch -> Pitch.Pitch
ascii_kbd_pitch pc_per_octave (Pitch.Pitch oct (Pitch.Degree pc accs)) =
    Pitch.Pitch (add_oct + oct1) (Pitch.Degree pc2 accs)
    where
    (oct1, pc1) = adjust_octave pc_per_octave 10 oct pc
    -- If the scale is shorter than the kbd, go up to the next octave on
    -- the same row.
    (add_oct, pc2) = pc1 `divMod` pc_per_octave

-- | Try to fit a note from a keyboard into a scale.  Round the note up to the
-- nearest multiple of the keyboard octave and adjust the octave accordingly.
adjust_octave :: Pitch.PitchClass -> Pitch.PitchClass -> Pitch.Octave
    -> Pitch.PitchClass -> (Pitch.Octave, Pitch.PitchClass)
adjust_octave pc_per_octave kbd_per_octave oct pc =
    (oct2, offset * kbd_per_octave + pc)
    where
    rows = ceiling $ fromIntegral pc_per_octave / fromIntegral kbd_per_octave
    (oct2, offset) = oct `divMod` rows


-- ** call_doc

call_doc :: Set.Set Score.Control -> DegreeMap -> Text -> Derive.DocumentedCall
call_doc transposers dmap doc =
    annotate_call_doc transposers doc fields default_scale_degree_doc
    where
    fields = [("note range", map_range snd (dm_to_note dmap))]
    map_range extract fm = case (Map.min fm, Map.max fm) of
        (Just kv1, Just kv2) -> txt (Pretty.pretty (extract kv1))
            <> " to " <> txt (Pretty.pretty (extract kv2))
        _ -> ""

-- | Documentation of the standard 'Call.Pitch.scale_degree'.
default_scale_degree_doc :: Derive.DocumentedCall
default_scale_degree_doc = scale_degree_doc ScaleDegree.scale_degree

scale_degree_doc ::
    (PitchSignal.Scale -> Scale.PitchNn -> Scale.PitchNote -> Derive.ValCall)
    -> Derive.DocumentedCall
scale_degree_doc scale_degree =
    Derive.extract_val_doc $ scale_degree PitchSignal.no_scale err err
    where err _ = Left $ PitchSignal.PitchError "it was just an example!"

annotate_call_doc :: Set.Set Score.Control -> Text -> [(Text, Text)]
    -> Derive.DocumentedCall -> Derive.DocumentedCall
annotate_call_doc transposers doc fields = Derive.prepend_doc extra_doc
    where
    extra_doc = doc <> "\n\n" <> join (transposers_field <> fields)
    transposers_field =
        [("transposers", txt $ Pretty.pretty transposers)
            | not (Set.null transposers)]
    join = Text.unlines
        . map (\(k, v) -> k <> ": " <> v) . filter (not . Text.null . snd)

add_doc :: Text -> Scale.Scale -> Scale.Scale
add_doc doc scale = scale
    { Scale.scale_call_doc = Derive.prepend_doc doc (Scale.scale_call_doc scale)
    }

-- * util

no_enharmonics :: Derive.Enharmonics
no_enharmonics _ _ = Right []

read_environ :: (TrackLang.Typecheck a) => (a -> Maybe val) -> val
    -> TrackLang.ValName -> TrackLang.Environ -> Either Scale.ScaleError val
read_environ read_val deflt name env = case TrackLang.get_val name env of
    Left (TrackLang.WrongType expected) ->
        unparseable ("expected type " <> txt (Pretty.pretty expected))
    Left TrackLang.NotFound -> Right deflt
    Right val -> parse val
    where
    parse val = maybe (unparseable (ShowVal.show_val val)) Right (read_val val)
    unparseable = Left . Scale.UnparseableEnviron name

maybe_key :: Pitch.Key -> Maybe a -> Either Scale.ScaleError a
maybe_key (Pitch.Key txt) =
    maybe (Left $ Scale.UnparseableEnviron Environ.key txt) Right