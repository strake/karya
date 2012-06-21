{-# LANGUAGE GeneralizedNewtypeDeriving, OverloadedStrings #-}
-- | Convert from Score events to a lilypond score.
module Perform.Lilypond.Lilypond where
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe

import qualified Text.PrettyPrint as PP
import Text.PrettyPrint (Doc)
import Text.PrettyPrint ((<+>), ($+$))

import Util.Control
import qualified Util.ParseBs as ParseBs
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq

import qualified Derive.Scale.Theory as Theory
import qualified Derive.Scale.Twelve as Twelve
import qualified Derive.Score as Score

import qualified Perform.Pitch as Pitch


-- * types

-- | Convert a value to its lilypond representation.
-- TODO go to Pretty.Doc instead of String?
class ToLily a where
    to_lily :: a -> String

-- | Time in score units.  The maximum resolution is a 128th note, so one unit
-- is 128th of a whole note.
newtype Time = Time Int deriving (Eq, Ord, Show, Num, Enum, Real, Integral)

instance Pretty.Pretty Time where
    pretty (Time t) = show t ++ "t"

time_per_whole :: Time
time_per_whole = Time 128

-- | This time duration measured as the fraction of a whole note.
data Duration = D1 | D2 | D4 | D8 | D16 | D32 | D64 | D128
    deriving (Enum, Eq, Ord, Show)

data NoteDuration = NoteDuration Duration Bool
    deriving (Eq, Show)

read_duration :: String -> Maybe Duration
read_duration s = case s of
    -- GHC incorrectly reports overlapping patterns.  This bug is fixed in 7.4.
    "1" -> Just D1; "2" -> Just D2; "4" -> Just D4; "8" -> Just D8
    "16" -> Just D16; "32" -> Just D32; "64" -> Just D64; "128" -> Just D128
    _ -> Nothing

instance ToLily Duration where
    to_lily = drop 1 . show

instance ToLily NoteDuration where
    to_lily (NoteDuration dur dot) = to_lily dur ++ if dot then "." else ""

data TimeSignature = TimeSignature { time_num :: !Int, time_denom :: !Duration }
    deriving (Show)

instance ToLily TimeSignature where
    to_lily (TimeSignature num denom) = show num ++ "/" ++ to_lily denom

data Event = Event {
    event_start :: !Time
    , event_duration :: !Time
    , event_pitch :: !String
    , event_instrument :: !Score.Instrument
    } deriving (Show)

event_end :: Event -> Time
event_end event = event_start event + event_duration event

instance Pretty.Pretty Event where
    format (Event start dur pitch inst) = Pretty.constructor "Event"
        [Pretty.format start, Pretty.format dur, Pretty.text pitch,
            Pretty.format inst]

-- ** Note

data Note = Note {
    -- | [] means this is a rest, and greater than one pitch indicates a chord.
    note_pitch :: ![String]
    , note_duration :: !NoteDuration
    , note_tie :: !Bool
    } deriving (Show)

note :: [String] -> NoteDuration -> Bool -> Note
note pitches dur tie = Note pitches dur tie

rest :: NoteDuration -> Note
rest dur = Note [] dur False

instance ToLily Note where
    to_lily (Note pitches dur tie) = case pitches of
            [] -> 'r' : ly_dur
            [pitch] -> pitch ++ ly_dur
            _ -> '<' : unwords pitches ++ ">" ++ ly_dur
        where ly_dur = to_lily dur ++ if tie then "~" else ""

note_time :: Note -> Time
note_time = note_dur_to_time . note_duration


-- * convert

-- | Turn Events, which are in absolute Time, into Notes, which are divided up
-- into tied Durations depending on the time signature.
convert_notes :: Bool -- ^ emit dotted rests?
    -> TimeSignature -> [Event] -> [Note]
convert_notes dotted_rests sig events = go 0 events
    where
    go prev [] = trailing_rests prev
    go prev events@(event:_) =
        mkrests prev start ++ mknotes start (event_duration event)
            (map event_pitch here)
        ++ go (event_end event) rest
        where
        -- TODO This only works for chords where all the notes have the same
        -- duration.  If the durations are different, I need to collect all
        -- overlapping notes, convert their durations individually but with
        -- the additional constraint that they have to tie at the same places,
        -- group vertically, and emit.
        start = event_start event
        (here, rest) = break ((/= event_start event) . event_start) events

    mkrests prev start
        | prev < start = map rest $
            convert_duration sig dotted_rests prev (start - prev)
        | otherwise = []
    mknotes start dur pitches = zipWith mk (finals durs) durs
        where
        mk is_final dur = note pitches dur (not is_final)
        durs = convert_duration sig True start dur
        finals = map null . drop 1 . List.tails
    trailing_rests end
        | remaining == 0 = []
        | otherwise = map rest $
            convert_duration sig dotted_rests end remaining
        where remaining = measure_time sig - end

-- | Given a starting point and a duration, emit the list of Durations
-- needed to express that duration.
convert_duration :: TimeSignature -> Bool -> Time -> Time -> [NoteDuration]
convert_duration sig use_dot pos time
    | time <= 0 = []
    | allowed >= time = time_to_note_durs time
    | otherwise = dur
        : convert_duration sig use_dot (pos + allowed) (time - allowed)
    where
    dur = time_to_note_dur allowed
    allowed = (if use_dot then allowed_dotted_time else allowed_time) sig pos

-- | Figure out how much time a note at the given position should be allowed
-- before it must tie.
-- TODO Only supports duple time signatures.
allowed_dotted_time :: TimeSignature -> Time -> Time
allowed_dotted_time sig measure_pos
    | pos == 0 = measure
    | otherwise = min measure next - pos
    where
    pos = measure_pos `mod` measure
    measure = measure_time sig
    level = log2 pos + 2
    -- TODO inefficient way to find the next power of 2 greater than pos.
    -- There must be a direct way.
    next = Maybe.fromJust (List.find (>pos) [0, 2^level ..])

-- | Like 'allowed_dotted_time', but only emit powers of two.
allowed_time :: TimeSignature -> Time -> Time
allowed_time sig pos = 2 ^ (log2 (allowed_dotted_time sig pos))

note_dur_to_time :: NoteDuration -> Time
note_dur_to_time (NoteDuration dur dotted) =
    dur_to_time dur + if dotted && dur /= D128 then dur_to_time (succ dur)
        else 0

dur_to_time :: Duration -> Time
dur_to_time dur = Time $ whole `div` case dur of
    D1 -> 1; D2 -> 2; D4 -> 4; D8 -> 8
    D16 -> 16; D32 -> 32; D64 -> 64; D128 -> 128
    where Time whole = time_per_whole

time_to_note_dur :: Time -> NoteDuration
time_to_note_dur t = case time_to_durs t of
    [d1, d2] | d2 == succ d1 -> NoteDuration d1 True
    d : _ -> NoteDuration d False
    -- I have no 0 duration, so I'm forced to pick something.
    [] -> NoteDuration D1 False

-- | This rounds up to the next Duration, so any Time over a half note will
-- wind up as a whole note.
time_to_dur :: Time -> Duration
time_to_dur (Time time) =
    toEnum $ min (fromEnum D128) (log2 (whole `div` time))
    where Time whole = time_per_whole

time_to_note_durs :: Time -> [NoteDuration]
time_to_note_durs t
    | t > 0 = dur : time_to_note_durs (t - note_dur_to_time dur)
    | otherwise = []
    where dur = time_to_note_dur t

time_to_durs :: Time -> [Duration]
time_to_durs (Time time) =
    map fst $ filter ((/=0) . snd) $ reverse $ zip durs (binary time)
    where
    durs = [D128, D64 ..]
    binary rest
        | rest > 0 = m : binary d
        | otherwise = []
        where (d, m) = rest `divMod` 2

-- | Integral log2.  So 63 is 0, because it divides by 2 zero times.
log2 :: (Integral a) => a -> Int
log2 = go 0
    where
    go n val
        | div > 0 && mod == 0 = go (n+1) div
        | otherwise = n
        where (div, mod) = val `divMod` 2

measure_time :: TimeSignature -> Time
measure_time sig = Time (time_num sig) * dur_to_time (time_denom sig)

measure_duration :: TimeSignature -> Duration
measure_duration (TimeSignature num denom) =
    time_to_dur $ Time num * dur_to_time denom

-- * score

data Score = Score {
    score_title :: String
    , score_time :: TimeSignature
    , score_clef :: Clef
    , score_key :: (String, Mode)
    } deriving (Show)

data Mode = Major | Minor deriving (Show)
type Clef = String

meta_ly :: String
meta_ly = "ly"

meta_title, meta_clef, meta_time_signature :: String
meta_title = "ly.title"
meta_clef = "ly.clef"
meta_time_signature = "ly.time-signature"
-- meta_duration1 = "ly.duration1"

meta_to_score :: Maybe Pitch.Key -> Map.Map String String
    -> Maybe (Either String Score)
meta_to_score maybe_score_key meta = case Map.lookup meta_ly meta of
    Nothing -> Nothing
    Just _ -> Just $ do
        score_key <- maybe (Left "key required") return maybe_score_key
        key <- parse_key score_key
        time_sig <- parse_time_signature $ get "4/4" meta_time_signature
        return $ Score
            { score_title = title
            , score_time = time_sig
            , score_clef = clef
            , score_key = key
            }
    where
    title = get "" meta_title
    clef = get "treble" meta_clef
    get deflt k = Map.findWithDefault deflt k meta
    parse_key key = case Map.lookup key Twelve.all_keys of
        Nothing -> Left $ "key not found: " ++ show key
        Just k -> do
            tonic <- show_pitch_note (Theory.key_tonic k)
            mode <- case Theory.key_name k of
                "maj" -> Right Major
                "min" -> Right Minor
                -- Actually lilypond supports a few church modes too.
                mode -> Left $ "unknown mode: " ++ show mode
            return (tonic, mode)

parse_time_signature :: String -> Either String TimeSignature
parse_time_signature sig = do
    let (num, post) = break (=='/') sig
        unparseable = Left $ "signature must be ##/##: " ++ show sig
    denom <- case post of
        '/' : d -> return d
        _ -> unparseable
    TimeSignature <$> maybe unparseable return (ParseBs.int num)
        <*> maybe unparseable return (read_duration denom)


-- * make_ly

make_staves :: String -> TimeSignature -> [Event] -> [Staff]
make_staves clef time_sig events =
    [ (clef, inst, convert_notes False time_sig inst_events)
    | (inst, inst_events) <- Seq.keyed_group_on event_instrument events
    ]

inst_name :: Score.Instrument -> String
inst_name = dropWhile (=='/') . dropWhile (/='/') . Score.inst_name

make_ly :: Score -> [Event] -> Doc
make_ly score events = ly_file score
    (make_staves (score_clef score) (score_time score) events)

type Staff = (Clef, Score.Instrument, [Note])

ly_file :: Score -> [Staff] -> Doc
ly_file (Score title time_sig _clef (key, mode)) staves =
    command "version" <+> string "2.14.2"
    $+$ command "language" <+> string "english"
    -- Could I put the stack in there so I can click on the notes and get them
    -- highlighted in the original score?
    $+$ command "pointAndClickOff"
    $+$ brackets (command "header")
        [assign name <+> string val | (name, val) <- [("title", title)]]
    $+$ command "score" <+> "{" <+> "<<"
    $+$ vsep (map mkstaff staves)
    $+$ ">>" <+> "}"
    where
    mkstaff (clef, inst, notes) = command "new" <+> "Staff"
        <+> "{"
            <+> command "clef" <+> string clef <+> "{"
            <+> command "key" <+> PP.text key
                <+> command (map Char.toLower (show mode))
            <+> command "time" <+> PP.text (to_lily time_sig)
            $+$ set "Staff.instrumentName" (string (inst_name inst))
            $+$ set "Staff.shortInstrumentName" (string (inst_name inst))
            $+$ brackets mempty (map (PP.text . to_lily) notes)
            <+> "}"
        <+> "}"

command :: String -> Doc
command text = PP.char '\\' <> PP.text text

bcommand :: String -> [Doc] -> Doc
bcommand text contents = command text <+> PP.char '{'
    $+$ PP.nest 2 (PP.fsep contents)
    $+$ PP.char '}'

brackets :: Doc -> [Doc] -> Doc
brackets prefix contents = prefix
    <+> PP.char '{' $+$ PP.nest 2 (PP.fsep contents) $+$ PP.char '}'

assign :: String -> Doc
assign name = PP.text name <+> PP.char '='

set :: String -> Doc -> Doc
set var val = command "set" <+> PP.text var <+> PP.char '=' <+> val

string :: String -> Doc
string = PP.doubleQuotes . PP.text

show_pitch :: Theory.Pitch -> Either String String
show_pitch pitch = (++ oct_mark) <$> show_pitch_note note
    where
    (octave, note) = Theory.split_pitch pitch
    oct_mark = let oct = octave - 3
        in if oct >= 0 then replicate oct '\'' else replicate (abs oct) ','

show_pitch_note :: Theory.Note -> Either String String
show_pitch_note (Theory.Note pc accs) = do
    acc <- case accs of
        -2 -> Right "ff"
        -1 -> Right "f"
        0 -> Right ""
        1 -> Right "s"
        2 -> Right "ss"
        _ -> Left $ "too many accidentals: " ++ show accs
    return $ Theory.pc_char pc : acc


-- * util

vsep :: [Doc] -> Doc
vsep = foldr ($+$) mempty
