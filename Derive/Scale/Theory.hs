-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE CPP #-}
{- | Functions to manipulate pitches in scales according to the rules of
    standard western music theory.

    Pitches are represented as 'Pitch'es and 'Note's.  They're generalized to
    work with any number of 'PitchClass'es, but since each scale carries an
    implied key 'Layout' it can only handle pitch classes in a certain range.
    Internally there are no checks that the pitch class is in range, so the
    only way to construct a Pitch or a Note is with 'read_pitch' or
    'read_note', which take a Layout for verification.

    Internally Pitches set A equal to 0, and thus wrap the octave at A.  This
    is contrary to common practice, which is to wrap the octave at C, so
    'read_pitch' and 'show_pitch' make this adjustment.

    @
        db      eb  fb      gb      ab      bb  cb
        c#      d#      e#  f#      g#      a#      b#
    c       d       e   f       g       a       b   c
    |   |   |   |   |   |   |   |   |   |   |   |   |
    @
-}
module Derive.Scale.Theory (
    diatonic_to_chromatic
    -- * symbolic transposition
    , transpose_diatonic, transpose_chromatic
    -- * input
    , enharmonics_of
    , pitch_to_semis, semis_to_pitch, semis_to_pitch_sharps
    , semis_to_nn, nn_to_semis
    -- * types
    , PitchClass, Degree, Semi, Octave, Accidentals, char_pc, pc_char
    , Pitch(..), pitch_accidentals
    , pitch_c_octave, modify_octave, transpose_pitch
    , Note(..), note_in_layout
    -- ** key
    , Key(key_tonic, key_name, key_layout), key, show_key
    , key_degrees_per_octave
    , layout
    -- * util
    , diatonic_degree_of
#ifndef TESTING
    , Layout(layout_intervals)
#else
    , Layout(..)
    , calculate_signature, degree_of
#endif
) where
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified Data.Text as Text
import qualified Data.Vector as Boxed
import qualified Data.Vector.Unboxed as Vector

import Util.Control
import qualified Util.Num as Num
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq
import qualified Util.Vector as Vector

import qualified Perform.Pitch as Pitch


-- * NoteNumber diatonic transposition

-- | Convert a fractional number of diatonic steps to chromatic steps.
diatonic_to_chromatic :: Key -> Note -> Double -> Double
diatonic_to_chromatic key note steps
    | steps == 0 = 0
    | steps > 0 = Num.scale (transpose isteps) (transpose (isteps+1)) frac
    | otherwise =
        Num.scale (transpose (isteps-1)) (transpose isteps) (1 - abs frac)
    where
    (isteps, frac) = properFraction steps
    transpose = fromIntegral . chromatic_steps key note

-- | Convert diatonic steps to chromatic steps.
chromatic_steps :: Key -> Note -> Int -> Semi
chromatic_steps key note steps =
    case table Vector.!? (middle + degree + steps2) of
        Just val -> oct_semis + val - table Vector.! (middle + degree)
        -- 'make_table' should build a table big enough that this can't happen.
        Nothing -> error $ "ran out of transpose table for "
            ++ show (middle, degree, steps2) ++ ": " ++ show table
    where
    degree = degree_of key note
    (octaves, steps2) = steps `divMod` key_degrees_per_octave key
    oct_semis = if octaves == 0 then 0
        else octaves * layout_semis_per_octave (key_layout key)
    middle = Vector.length table `div` 2
    table = key_transpose_table key

-- * symbolic transposition

-- | Transpose a pitch diatonically.  If the key is diatonic (i.e. there is
-- a 1:1 relationship between note letters and scale degrees), then this will
-- increment or decrement the note letters by the number of steps and adjust
-- the accidentals based on the key signature.  Otherwise (i.e. for scales like
-- whole-tone or octatonic), it will figure out the number of chromatic steps
-- to transpose and act like 'transpose_chromatic'.
transpose_diatonic :: Key -> Degree -> Pitch -> Pitch
transpose_diatonic key steps pitch@(Pitch oct note)
    | steps == 0 = pitch
    | otherwise = case key_signature key of
        Just sig -> Pitch (oct + oct2)
            (Note pc2 (note_accidentals note + key_accs sig pc2))
        Nothing -> transpose_chromatic
            key (chromatic_steps key note steps) pitch
    where
    (oct2, pc2) = (note_pc note + steps) `divMod` key_degrees_per_octave key
    key_accs sig pc = fromMaybe 0 $ sig Vector.!? diatonic_degree_of key pc

-- | Chromatic transposition.  Try to pick a spelling that makes sense for the
-- given key.
transpose_chromatic :: Key -> Semi -> Pitch -> Pitch
transpose_chromatic key steps pitch
    | steps == 0 = pitch
    | otherwise = semis_to_pitch key $ pitch_to_semis layout pitch + steps
    where layout = key_layout key

pitch_to_semis :: Layout -> Pitch -> Semi
pitch_to_semis layout (Pitch oct note) =
    oct * layout_semis_per_octave layout + note_to_semis layout note

note_to_semis :: Layout -> Note -> Semi
note_to_semis layout (Note pc accs) =
    Vector.sum (Vector.take pc (layout_intervals layout)) + accs

-- | Convert an absolute semitones values to a pitch.  This is a bit
-- complicated because it wants to find the best spelling for the given key.
semis_to_pitch :: Key -> Semi -> Pitch
semis_to_pitch key semis = mkpitch $ case key_signature key of
        Just sig -> case List.find (in_scale sig) enharmonics of
            Nothing -> pick_enharmonic (sharp_signature sig) enharmonics
            Just note -> note
        Nothing -> pick_enharmonic (sharp_tonic key) enharmonics
    where
    mkpitch (oct, note) = Pitch (octave + oct) note
    -- The (Note (-1) 0) error value is icky, but here's why it should never
    -- happen: It happens when enharmonics is empty.  Since the values of
    -- layout_enharmonics are never [] as per the definition of 'layout', it
    -- means the mod of semis is out of range for the array, which means the
    -- sum of the intervals is larger than the length of layout_enharmonics.
    -- That shouldn't happen because layout_enharmonics is initialized to
    -- [..  | i <- intervals, a <- [0..i-1]].
    pick_enharmonic use_sharps notes = fromMaybe (0, Note (-1) 0) $
        Seq.minimum_on (key . note_accidentals . snd) notes
        where key accs = (if use_sharps then accs < 0 else accs > 0, abs accs)
    in_scale sig (_, note) =
        sig Vector.!? degree_of key note == Just (note_accidentals note)
    enharmonics = fromMaybe [] $ layout_enharmonics layout Boxed.!? steps
    (octave, steps) = semis `divMod` layout_semis_per_octave layout
    layout = key_layout key
    -- Sharpish looking key signatures favor sharps.
    sharp_signature sig = Vector.count (>0) sig >= Vector.count (<0) sig
    sharp_tonic = (>=0) . note_accidentals . key_tonic

-- | Like 'semis_to_pitch', but only ever emits sharps, so it doesn't require
-- a key.
semis_to_pitch_sharps :: Layout -> Semi -> Pitch
semis_to_pitch_sharps layout semis = Pitch (octave + oct) note
    where
    (octave, steps) = semis `divMod` 12
    (oct, note) = head $ enharmonics Boxed.! steps
    enharmonics = layout_enharmonics layout

-- | Convert Semis to integral nns.  Semis count from A while NNs start at C.
-- It doesn't return NoteNumber because these values are specifically integral,
-- and are likely going to be turned into an integral flavor of NoteNumbers,
-- like Pitch.Degree.
semis_to_nn :: Semi -> Int
semis_to_nn = subtract 3

nn_to_semis :: Int -> Semi
nn_to_semis = (+ 3)

-- * input

-- | Enharmonics of a note, along with an octave offset if the enharmonic
-- wrapped an octave boundary.
--
-- This choses the next highest enharmonic until it wraps around, so if you
-- repeatedly pick the first one you'll cycle through them all.
enharmonics_of :: Layout -> Pitch -> [Pitch]
enharmonics_of layout pitch =
    [Pitch (pitch_octave pitch + oct) n | (oct, n) <- ens]
    where ens = get_enharmonics (layout_intervals layout) (pitch_note pitch)

-- * types

-- ** pitch types

-- | A PitchClass maps directly to a letter, starting at @a@.  So the usual
-- a--g is represented as 0--6, but of course scales with more or fewer notes
-- per octave may use different ranges.  The PitchClass is also absolute in
-- that it doesn't depend on the tonic of a key.
type PitchClass = Int

-- | A degree is one step of a scale.  Unlike 'PitchClass' it's relative to the
-- tonic of the key, but also may have a different range.  This is because some
-- scales, such as whole-tone or octatonic, have fewer or more degrees than 7,
-- which means that not every Degree will map to a PitchClass.  Another
-- approach is to change the number of PitchClasses, this would result in a--h
-- for octatonic, but it would not admit easy modulation from an octatonic
-- scale to a septatonic one.
--
-- 'Key' has more documentation about the PitchClass and Degree distinction.
type Degree = Int

-- | Number of semitones.
type Semi = Int
-- | Middle C is octave 4.
type Octave = Int

-- | Positive for sharps, negative for flats.
type Accidentals = Int

char_pc :: Char -> PitchClass
char_pc c = fromEnum c - fromEnum 'a'

pc_char :: PitchClass -> Char
pc_char pc = toEnum (fromEnum 'a' + pc)

-- *** Pitch

-- | A Pitch is just a Note with an octave.
data Pitch = Pitch {
    pitch_octave :: !Octave
    , pitch_note :: !Note
    } deriving (Eq, Show)

-- | This subtracts 2 from the octave so that middle C winds up at octave 4,
-- and the bottom of the range ends up at octave -1.
instance Pretty.Pretty Pitch where
    pretty pitch = show (oct - 2) <> Pretty.pretty note
        where (oct, note) = pitch_c_octave pitch

-- | Extract the octave from the Note, wrapping it at C.
pitch_c_octave :: Pitch -> (Octave, Note)
pitch_c_octave (Pitch octave note) =
    (if note_pc note >= 2 then octave + 1 else octave, note)

pitch_accidentals :: Pitch -> Accidentals
pitch_accidentals = note_accidentals . pitch_note

modify_octave :: (Octave -> Octave) -> Pitch -> Pitch
modify_octave f (Pitch octave note) = Pitch (f octave) note

-- | Transpose a pitch by diatonic steps.  Simpler than 'transpose_diatonic'
-- in that it doesn't deal with key signatures or non-diatonic scales at all.
transpose_pitch :: Degree -> Semi -> Pitch -> Pitch
transpose_pitch per_oct steps (Pitch octave (Note pc accs)) =
    Pitch (oct + octave) (Note pc2 accs)
    where (oct, pc2) = (pc + steps) `divMod` per_oct


-- *** Note

data Note = Note {
    note_pc :: !PitchClass
    , note_accidentals :: !Accidentals
    } deriving (Eq, Show)

instance Pretty.Pretty Note where
    pretty (Note pc acc) = untxt $ Text.cons (pc_char pc) $
        if acc < 0 then Text.replicate (abs acc) "b" else Text.replicate acc "#"

note_in_layout :: Layout -> Note -> Bool
note_in_layout layout note =
    0 <= note_pc note && note_pc note < layout_max_pc layout

-- * Key

-- | A Key is a scale along with a tonic Pitch.
--
-- There's a distinction between \"diatonic\" and \"chromatic\" keys.  It's not
-- really standard terminology, but within this module I call scales with a 1:1
-- 'PitchClass' : 'Degree' mapping \"diatonic\", and the ones without
-- \"chromatic\".  That's because diatonic transposition for the former kind of
-- scale is defined in terms of pitch classes, regardless of what accidentals
-- the Note may have, but the latter kind of scale must resort to chromatic
-- transposition, losing the spelling of the original note.  Ultimately there
-- is a tension between diatonic and chromatic systems.
data Key = Key {
    key_tonic :: !Note
    , key_name :: !Text
    -- | Semitones between each scale degree.  This should have at least two
    -- octaves of intervals, as needed by 'chromatic_steps'.  If this is a
    -- diatonic key, each interval is one pitch class.
    , key_intervals :: Intervals
    , key_signature :: Maybe Signature
    -- | Table to speed up diatonic transposition, see 'make_table'.
    , key_transpose_table :: Intervals
    , key_layout :: Layout
    } deriving (Eq, Show)

-- | Map from a Degree to the number of sharps or flats at that Degree.
type Signature = Vector.Vector Accidentals
type Intervals = Vector.Vector Semi

-- Make a Key given intervals and a layout.  If the number of intervals are
-- equal to the number of intervals in the layout, the scale is considered
-- diatonic and will get a 'Signature'.
key :: Note -> Text -> [Accidentals] -> Layout -> Key
key tonic name intervals layout = Key
    { key_tonic = tonic
    , key_name = name
    , key_intervals = int
    , key_signature = generate_signature tonic layout int
    , key_transpose_table = make_table intervals
    , key_layout = layout
    }
    where int = Vector.fromList intervals

show_key :: Key -> Pitch.Key
show_key key = Pitch.Key $
    Pretty.prettytxt (key_tonic key) <> "-" <> key_name key

-- | Precalculated transpositions so I can figure out a transposition with
-- a single table lookup.  This goes out to two octaves on either direction
-- so I can start at any degree and go up to an octave of transposition.
-- Everything past an octave is chopped off by divMod and transposed with
-- multiplication.
make_table :: [Int] -> Intervals
make_table intervals = Vector.fromList $
    reverse (drop 1 (make (-) (reverse intervals))) ++ make (+) intervals
    where make f = take (length intervals * 2) . scanl f 0 . cycle

generate_signature :: Note -> Layout -> Intervals -> Maybe Signature
generate_signature tonic layout intervals
    | Vector.length (layout_intervals layout) /= Vector.length intervals =
        Nothing
    | otherwise = Just $
        calculate_signature tonic (layout_intervals layout) intervals

calculate_signature :: Note -> Intervals -> Intervals -> Intervals
calculate_signature (Note pc accs) layout intervals =
    Vector.take (Vector.length intervals) $
        Vector.zipWith subtract (Vector.scanl (+) 0 (rotate pc layout))
            (Vector.scanl (+) accs intervals)
    where
    rotate n xs = post <> pre
        where (pre, post) = Vector.splitAt n xs

key_is_diatonic :: Key -> Bool
key_is_diatonic = Maybe.isJust . key_signature

instance Pretty.Pretty Key where
    format key@(Key tonic name ints sig _table _layout) = Pretty.record title
        [ ("intervals",
            Pretty.format (Vector.take (key_degrees_per_octave key) ints))
        , ("signature", Pretty.format sig)
        ]
        where
        title = Pretty.text "Key" Pretty.<+> Pretty.format tonic
            Pretty.<+> Pretty.text (untxt name)

-- | Number of degrees in an octave for this scale.
--
-- This is different from the number of PCs per octave, because scales like
-- octatonic or whole tone don't have a mapping from PCs to scale degrees.
key_degrees_per_octave :: Key -> Degree
key_degrees_per_octave = Vector.length . key_intervals

layout_semis_per_octave :: Layout -> Semi
layout_semis_per_octave = Vector.sum . layout_intervals

-- | One greater than the maximum pitch class defined for this key.
layout_max_pc :: Layout -> PitchClass
layout_max_pc = Vector.length . layout_intervals

-- | Figure out the scale degree of a note in the given key.
degree_of :: Key -> Note -> Degree
degree_of key note
    | key_is_diatonic key = diatonic_degree_of key (note_pc note)
    | otherwise = Vector.find_before semis (key_intervals key)
    where semis = note_to_semis (key_layout key) note

-- | Figure out the score degree of a diatonic key.  In a diatonic key, the
-- degree and pitch class are relative and absolute versions of the same thing.
diatonic_degree_of :: Key -> PitchClass -> PitchClass
diatonic_degree_of key pc =
    (pc - note_pc (key_tonic key)) `mod` key_degrees_per_octave key

-- ** Layout

-- | A Layout represents the configuration of white and black keys.
data Layout = Layout {
    -- | Map PitchClass to the number of sharps above it.
    layout_intervals :: !Intervals
    -- | Map PitchClass to the enharmonic Notes at that PitchClass.
    , layout_enharmonics :: !(Boxed.Vector [(Octave, Note)])
    } deriving (Eq, Show)

layout :: [Accidentals] -> Layout
layout intervals =
    Layout vec $ Boxed.fromList $
        map (\n -> (0, n) : get_enharmonics vec n) notes
    where
    vec = Vector.fromList intervals
    notes = [Note pc accs | (pc, int) <- zip [0..] intervals,
        accs <- [0..int-1]]

get_enharmonics :: Intervals -> Note -> [(Octave, Note)]
get_enharmonics intervals (Note note_pc note_accs) =
    [ mknote intervals (note_pc + pc) (note_accs + accs)
    | (pc, accs) <- pcs, abs (note_accs + accs) < 3
    ]
    where
    -- Find the distance in semitones from neighbor pcs.
    pcs =
        [ (1, -diffs [0])
        , (2, -diffs [0, 1])
        , (-2, diffs [-2, -1])
        , (-1, diffs [-1])
        ]
    diffs = sum . map (layout_at intervals . (note_pc+))
    mknote intervals pc accs = (oct, Note pc2 accs)
        where (oct, pc2) = pc `divMod` Vector.length intervals

layout_at :: Intervals -> PitchClass -> Accidentals
layout_at intervals pc =
    fromMaybe 0 $ intervals Vector.!? (pc `mod` Vector.length intervals)
