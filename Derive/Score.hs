{- | This has the basic data structures for the deriver level.

    The events here are generated from UI Events, and will eventually be
    transformed into Perform Events, which are specific to the performance
    backend.
-}
module Derive.Score where
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as Text

import Ui

import qualified Perform.Signal as Signal
import qualified Perform.PitchSignal as PitchSignal
import qualified Perform.Warning as Warning


-- | Currently this is just for 'Derive.map_events'.
class Eventlike e where
    stack :: e -> [Warning.StackPos]

data Event = Event {
    -- | These are the core attributes that define an event.  UI display
    -- attributes like font style are not preserved here.
    event_start :: TrackPos
    , event_duration :: TrackPos
    -- | The UI level keeps it in UTF8 for easy communication with fltk, but
    -- haskell will always need to decode it, so I might as well do it here.
    , event_text :: Text.Text
    , event_controls :: ControlMap
    , event_pitch :: PitchSignal.PitchSignal

    -- | Keep track of this event's display in various tracks (it may appear
    -- in more than one if it appears in a merged track).  That way, if an
    -- error or warning is emitted concerning this event, its position on the
    -- UI can be highlighted.
    , event_stack :: [Warning.StackPos]

    -- | These are optional parameters that may or may not be required by the
    -- performer.
    , event_instrument :: Maybe Instrument
    , event_attributes :: Attributes
    } deriving (Eq, Show)

instance Eventlike Event where
    stack = event_stack

event_string :: Event -> String
event_string = Text.unpack . event_text

event_end :: Event -> TrackPos
event_end event = event_start event + event_duration event

type ControlMap = Map.Map Control Signal.Control

data ControlEvent = ControlEvent {
    cevent_start :: TrackPos
    , cevent_text :: Text.Text
    , cevent_stack :: [Warning.StackPos]
    } deriving (Eq, Show)

instance Eventlike ControlEvent where
    stack = cevent_stack

cevent_string :: ControlEvent -> String
cevent_string = Text.unpack . cevent_text

-- | An Instrument is identified by a plain string.  This will be looked up in
-- the instrument db to get the backend specific Instrument type as well as the
-- backend itself, but things at the Derive layer and above don't care about
-- all that.
data Instrument = Instrument String
    deriving (Eq, Ord, Show, Read)
inst_name (Instrument s) = s

-- | Instruments can have a set of attributes along with them.  These are
-- propagated dynamically down the derivation stack.  They function like
-- arguments to an instrument, and will typically select an articulation, or
-- a drum from a drumset, or something like that.
type Attribute = String
type Attributes = Set.Set Attribute
no_attrs :: Attributes
no_attrs = Set.empty

newtype Control = Control String deriving (Eq, Ord, Show)

-- * attributes

-- ** articulations

pizz = "pizz"
trem = "trem"

-- ** dynamics

cresc = "cresc"
dim = "dim"
sfz = "sfz"
