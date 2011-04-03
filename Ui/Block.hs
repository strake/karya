module Ui.Block where
import qualified Control.DeepSeq as DeepSeq
import qualified Data.Map as Map
import qualified Util.Seq as Seq

import Ui
import qualified Ui.Color as Color
import qualified Ui.Ruler as Ruler
import qualified Ui.Skeleton as Skeleton
import qualified Ui.Track as Track
import qualified Ui.Types as Types

import qualified App.Config as Config


-- * block model

data GenericBlock track = Block {
    block_title :: String
    , block_config :: Config
    , block_tracks :: [track]
    , block_skeleton :: Skeleton.Skeleton
    , block_schema :: SchemaId
    } deriving (Eq, Show, Read)

instance DeepSeq.NFData (GenericBlock track) where
    -- I don't bother to force anything deep, but there isn't much data down
    -- there anyway.
    rnf (Block title config tracks skel schema) =
        title `seq` config `seq` tracks `seq` skel `seq` schema `seq` ()

type Block = GenericBlock BlockTrack
type DisplayBlock = GenericBlock DisplayTrack

block_tracklike_ids :: Block -> [TracklikeId]
block_tracklike_ids = map tracklike_id . block_tracks

block_track_ids :: Block -> [TrackId]
block_track_ids = track_ids_of . block_tracklike_ids

block_ruler_ids :: Block -> [RulerId]
block_ruler_ids = ruler_ids_of . block_tracklike_ids

block :: Config -> String  -> [BlockTrack] -> SchemaId -> Block
block config title tracks schema_id =
    Block title config tracks Skeleton.empty schema_id

-- | Per-block configuration.
data Config = Config {
    config_selection_colors :: [Color.Color]
    , config_bg_color :: Color.Color
    , config_track_box :: (Color.Color, Char)
    , config_sb_box :: (Color.Color, Char)
    } deriving (Eq, Show, Read)

default_config :: Config
default_config = Config
    Config.bconfig_selection_colors Config.bconfig_bg_color
    Config.bconfig_track_box Config.bconfig_sb_box

data BlockTrack = BlockTrack {
    tracklike_id :: TracklikeId
    -- | The current width is in the View, but this width is a default if
    -- a new View is created from this Block.
    , track_width :: Types.Width
    -- | Track display state flags.
    , track_flags :: [TrackFlag]
    -- | Other tracks are displayed behind this one.  Useful to merge a pitch
    -- track into its note track.
    , track_merged :: [TrackId]
    } deriving (Eq, Show, Read)

-- | Construct a 'BlockTrack' with defaults.
block_track :: TracklikeId -> Types.Width -> BlockTrack
block_track tracklike_id width = BlockTrack tracklike_id width [] []

-- | Similar to Track.Track, except this data can vary per-block.
data DisplayTrack = DisplayTrack {
    dtrack_tracklike_id :: TracklikeId
    , dtrack_merged :: [TrackId]
    , dtrack_status :: Maybe (Char, Color.Color)
    , dtrack_event_brightness :: Double
    , dtrack_collapsed :: Bool
    } deriving (Eq, Show, Read)

-- | Most of these only make sense for event tracks.
data TrackFlag =
    -- | Track is collapsed to take up less space.
    Collapse
    -- | UI shows solo indication.  If any tracks are soloed on a block, only
    -- those tracks are derived.
    | Solo
    -- | UI shows muted indication, deriver should skip this track.
    | Mute
    deriving (Eq, Show, Read)

-- | Convert logical block level tracks to display tracks.  Return the
-- track creation width since it doesn't belong in DisplayTrack.
block_display_tracks :: Block -> [(DisplayTrack, Types.Width)]
block_display_tracks block =
    [(block_track_config t, track_width t) | t <- block_tracks block]

block_track_config :: BlockTrack -> DisplayTrack
block_track_config btrack =
    DisplayTrack (tracklike_id btrack) (track_merged btrack) status brightness
        (Collapse `elem` track_flags btrack)
    where (status, brightness) = flags_to_status (track_flags btrack)

flags_to_status :: [TrackFlag] -> (Maybe (Char, Color.Color), Double)
flags_to_status flags
    | Solo `elem` flags = (Just ('S', Config.solo_color), 1)
    | Mute `elem` flags = (Just ('M', Config.mute_color), 0.75)
    | otherwise = (Nothing, 1)

modify_id :: BlockTrack -> (TracklikeId -> TracklikeId) -> BlockTrack
modify_id track f = track { tracklike_id = f (tracklike_id track) }

data TracklikeId =
    -- | Tracks may have a Ruler overlay
    TId TrackId RulerId
    | RId RulerId
    | DId Divider
    deriving (Eq, Show, Read)

track_id_of :: TracklikeId -> Maybe TrackId
track_id_of (TId tid _) = Just tid
track_id_of _ = Nothing

track_ids_of = Seq.map_maybe track_id_of

ruler_id_of :: TracklikeId -> Maybe RulerId
ruler_id_of (TId _ rid) = Just rid
ruler_id_of (RId rid) = Just rid
ruler_id_of _ = Nothing

ruler_ids_of = Seq.map_maybe ruler_id_of

set_rid rid (TId tid _) = TId tid rid
set_rid rid (RId _) = RId rid
set_rid _ t = t

data Tracklike =
    T Track.Track Ruler.Ruler
    | R Ruler.Ruler
    | D Divider
    deriving (Show)

track_of :: Tracklike -> Maybe Track.Track
track_of (T track _) = Just track
track_of _ = Nothing

tracks_of = Seq.map_maybe track_of

ruler_of :: Tracklike -> Maybe Ruler.Ruler
ruler_of (T _ ruler) = Just ruler
ruler_of (R ruler) = Just ruler
ruler_of _ = Nothing

rulers_of = Seq.map_maybe ruler_of

-- | A divider separating tracks.
-- Defined here in Block since it's so trivial.
data Divider = Divider Color.Color deriving (Eq, Ord, Show, Read)

-- * block view

data View = View {
    -- | view_block should never change.
    -- TODO Views that point to a BlockId not in state_blocks should be
    -- destroyed.
    view_block :: BlockId
    , view_rect :: Types.Rect

    -- | Pixel width and height of the track area of the view, i.e. view_rect
    -- with scrollbars and other things subtracted.
    --
    -- These two are derived from view_rect, but only fltk knows the width of
    -- all the various widgets, so it's cached here so pure code doesn't have
    -- to call to the UI and import BlockC.
    , view_visible_track :: Int
    , view_visible_time :: Int

    , view_config :: ViewConfig
    , view_status :: Map.Map String String

    -- | Scroll and zoom
    , view_track_scroll :: Types.Width
    , view_zoom :: Types.Zoom

    , view_selections :: Map.Map Types.SelNum Types.Selection
    -- | These are the per-view settings for the tracks.  There should be one
    -- corresponding to each TracklikeId in the Block.  The StateT operations
    -- should maintain this invariant.
    , view_tracks :: [TrackView]
    } deriving (Eq, Ord, Show, Read)

instance DeepSeq.NFData View where
    rnf (View bid rect track time config status scroll zoom selections tracks) =
        bid `seq` rect `seq` track `seq` time `seq` config `seq` status
        `seq` scroll `seq` zoom `seq` selections `seq` tracks `seq` ()

-- | Construct a View, using default values for most of its fields.
-- Don't construct views using View directly since State.create_view overwrites
-- view_tracks, and maybe more in the future.
view :: BlockId -> Types.Rect -> Types.Zoom -> View
view block_id rect zoom =
    -- view_visible_track and view_visible_time are unknown, but will
    -- be filled in when the new view emits its initial resize msg.
    View block_id rect 0 0 default_view_config Map.empty 0 zoom Map.empty []

show_status :: View -> String
show_status = Seq.join " | " . map (\(k, v) -> k ++ ": " ++ v)
    . Map.assocs . view_status

-- | Return how much track is in view.
visible_time :: View -> ScoreTime
visible_time view = Types.zoom_to_time (view_zoom view) (view_visible_time view)

visible_track :: View -> Types.Width
visible_track = view_visible_track

-- | Get the visible track widths, taking collapsed tracks into account.
--
-- TODO get rid of this grodiness by moving collapsed tracks back into haskell
visible_track_widths :: Block -> View -> [Types.Width]
visible_track_widths block view =
    zipWith size_of (view_tracks view) (block_tracks block)
    where
    size_of vtrack btrack
        | Collapse `elem` track_flags btrack = 3
        | otherwise = track_view_width vtrack

-- | If the given Rect is the visible area, expand it to be what the
-- 'view_rect' would be for that visible area.  Use this to set the visible
-- area to a certain size.
set_visible_rect :: View -> Types.Rect -> Types.Rect
set_visible_rect view rect = rect
    -- Add a bit of padding to look nicer.
    { Types.rect_w = Types.rect_w rect + dw + 2
    , Types.rect_h = Types.rect_h rect + dh
    }
    where
    dw = Types.rect_w (view_rect view) - view_visible_track view
    dh = Types.rect_h (view_rect view) - view_visible_time view

data TrackView = TrackView {
    track_view_width :: Types.Width
    -- TODO add track_view_collapsed here
    } deriving (Eq, Ord, Show, Read)

-- | These are defaults for newly created blocks.
data ViewConfig = ViewConfig {
    vconfig_block_title_height :: Int
    , vconfig_track_title_height :: Int
    , vconfig_skel_height :: Int
    , vconfig_sb_size :: Int
    , vconfig_status_size :: Int
    } deriving (Eq, Ord, Show, Read)

default_view_config :: ViewConfig
default_view_config = ViewConfig
    Config.vconfig_block_title_height
    Config.vconfig_track_title_height
    Config.vconfig_skel_height
    Config.vconfig_sb_size
    Config.vconfig_status_size
