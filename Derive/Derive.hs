{-

The derivation is simply a transformation from a Score to a Score.  Blocks can
be transformed into Scores and back again, so you can create blocks out of
intermediate derivations.

However, the standard derivations have this structure:

The caller of the deriver should expand collapsed tracks.  It can't eliminate
muted tracks because it doesn't know the scope of the tracks (e.g. if you mute
an instrument track, its dependent controllers are also muted), so mute status
is passed along with the track, possibly along with arbitrary other data, which
can parameterize the derivation... the derivation context.

Derivation context: implements behavioural abstraction.  Fill this out later.

Tracks are interpreted left to right.  The track name maps to (Deriver,
Extent), where the extent figures out how many tracks the deriver applies to.
For example, a tempo track will map to the next major division, and an
instrument track will map to the next instrument division (different kinds of
divisions are defined simply by convention: a given color and a given size).

An implicit "parallel" is wrapped around the whole block, and derivers like
"tempo" that apply to multiple tracks merge them in parallel.

So each derivation comes in a pair: one function to split [Tracklike] into ones
that belong to this derivation and the rest, and one function that takes
[Tracklike] -> [Tracklike].

Or maybe there should be an explicit way to group tracks.  Then I have
a supertrack label, like so:

data TrackGroup = TrackGroup (Maybe DeriverId) [TrackGroup]
    | SingleTrack Tracklike


(block
    (tempo
        (signal [])
        (inst "z1:string"
            (twelve [])
            (pres (signal [])))
        (inst "vl1:sax"
            (twelve [])
            (pres (+
                (signal [])
                (max 0.7 (signal []))))))

data TrackGraph = D String [D] | T TrackId | V String

D "block"
    [ D "tempo"
        [ D "signal" [T tempo_track]]
    , D "inst"
        [ V "z1:string"
        , D "twelve" [T string_track]
        , D "pressure" [D "signal" [T string_pressure_track]]
        ]
    , D "inst"
        [ V "vl1:sax"
        , D "twelve" [T sax_track]
        , D "pressure"
            [ D "+"
                [ D "signal" [T sax_pressure1_track]
                , D "max" [V "0.7", [T "signal" [T sax_pressure2_track]]]
                ]
            ]
        ]
    ]

max :: Signal -> Signal -> Signal
signal :: Track -> Signal
tempo :: Signal -> [Track] -> Track


one track controls pressure for two tracks (if they are midi the channel
allocator should take this into account and optimize them into one channel if
otherwise possible)

An arbitrary function (say "set_midi_interpolate n") within a given tracks,
from n TrackPos to m TrackPos.

Two "events" in the same event, either seperate them with ';' or support
simultaneous events, or a way to write them in another track?

-}
module Derive.Derive where
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.List as List

import Ui.Types
import qualified Ui.State as State
import qualified Ui.Block as Block
import qualified Ui.Track as Track

import qualified Perform.Timestamp as Timestamp
-- import qualified Derive.Player as Player


type Deriver = State.State -> Score -> Score
-- | Simplified version of a Block, with just the data the Deriver needs.
-- The block's ruler is prepended to its track list.
data Score = Score String [Block.Tracklike] deriving (Show)
score_tracks (Score _ tracks) = tracks

data Instrument = Instrument String Backend deriving (Show)
data Backend = MidiBackend deriving (Show)

get_block_score :: (State.UiStateMonad m) => Block.Block -> m Score
get_block_score block = do
    tracks <- mapM State.get_tracklike
        (Block.block_ruler_track block : map fst (Block.block_tracks block))
    return $ Score (Block.block_title block) tracks

-- * derivation

-- deriver may split block into instrument areas (split on track titles?)
-- derive block, keeping instruments, should wind up with (Instrument, Track)
-- group instruments with like backends, and pass each one to the renderer
-- derive :: Deriver -> State.State -> Score -> (Score, Player.TempoMap)
derive deriver state score = let derived = deriver state score
    in (derived, simple_tempo_map derived)

-- | It's linear.
-- Hardcoded tempo mapping, duplicated in Render.Midi.
simple_tempo_map score _block_id (Timestamp.Timestamp ts)
    | pos < end = Just pos
    | otherwise = Nothing
    where
    pos = TrackPos (floor (fromIntegral ts / 20))
    end = (maximum . map Track.time_end . event_tracks_of . score_tracks) score

event_tracks_of = Maybe.catMaybes . map event_track
event_track (Block.T track _) = Just track
event_track _ = Nothing

{-
-- | Given the tracks, decide which belong to which instruments and group them
-- into Parts.
extract_parts :: [Block.Tracklike] -> [Part]
extract_parts tracks = map
        (\tracks -> Part (track_title (head tracks)) tracks)
        groups
    where
    groups = filter (not.null) $ List.groupBy groupf tracks
    groupf t1 t2 = not (instrument_title (track_title t2))
data Part = Part {
    part_name :: String
    , part_tracks :: [Block.Tracklike]
    } deriving (Show)

track_title (Block.T track _) = (Track.track_title track)
track_title _ = ""

instrument_title = (==['>']) . take 1
-}

get_deriver :: Maybe Block.DeriverId -> Maybe Deriver
get_deriver deriver_id =
    maybe (Just default_deriver) (flip Map.lookup derivers) deriver_id

derivers :: Map.Map Block.DeriverId Deriver
derivers = Map.fromList
    [
    ]




-- * derivers

default_deriver :: Deriver
default_deriver state score = score
