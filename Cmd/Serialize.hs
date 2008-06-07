module Cmd.Serialize where

import qualified Control.Exception as Exception

import qualified Data.Binary as Binary
import Data.Binary (Binary, get, put, getWord8, putWord8)
import qualified Data.Time as Time

import qualified System.IO as IO
import qualified System.IO.Error as IO.Error
import qualified System.Directory as Directory

import Ui.Types
import qualified Ui.State as State
import qualified Ui.Color as Color
import qualified Ui.Font as Font
import qualified Ui.Block as Block
import qualified Ui.Ruler as Ruler
import qualified Ui.Event as Event
import qualified Ui.Track as Track

import qualified Perform.Midi.Instrument as Instrument
import qualified Midi.Midi as Midi

-- import BinaryDerive


serialize :: IO.FilePath -> SaveState -> IO ()
serialize fname state = do
    Exception.catchJust enoent_exc
        (Directory.renameFile fname (fname ++ ".last"))
        (\_exc -> return ())
    Binary.encodeFile fname state

serialize_text fname state = IO.writeFile fname (show state)

unserialize :: IO.FilePath
    -> IO (Either Exception.Exception SaveState)
unserialize fname = Exception.try (Binary.decodeFile fname)

unserialize_text fname = do
    [_ver, ui_str] <- fmap lines (IO.readFile fname)
    st <- Exception.try $ readIO ui_str
    case st of
        Left exc -> return (Left exc)
        Right ui_state -> fmap Right (save_state ui_state)

enoent_exc exc = case Exception.ioErrors exc of
    Just io_error | IO.Error.isDoesNotExistError io_error -> Just io_error
    _ -> Nothing


-- * data types

data SaveState = SaveState {
    save_ui_state :: State.State
    , save_date :: Time.UTCTime
    -- undo-related metadata?
    } deriving (Show)
save_state ui_state = do
    utc <- Time.getCurrentTime
    return (SaveState ui_state utc)

put_version n = Binary.putWord8 n
get_version = Binary.getWord8

throw = error
version_error typ ver = throw $
    "unknown version " ++ show ver ++ " for " ++ show typ

-- * binary instances

instance Binary SaveState where
    put (SaveState a b) = put_version 0
        >> put a >> put b
    get = do
        v <- get_version
        case v of
            0 -> get >>= \a -> get >>= \b -> return (SaveState a b)
            _ -> version_error "SaveState" v

instance Binary State.State where
    put (State.State a b c d e) = put_version 0
        >> put a >> put b >> put c >> put d >> put e
    get = do
        v <- get_version
        case v of
            0 -> get >>= \a -> get >>= \b -> get >>= \c -> get >>= \d ->
                get >>= \e -> return (State.State a b c d e)
            _ -> version_error "State.State" v

-- ** Block

instance Binary Block.BlockId where
    put (Block.BlockId a) = put a
    get = get >>= \a -> return (Block.BlockId a)

instance Binary Block.ViewId where
    put (Block.ViewId a) = put a
    get = get >>= \a -> return (Block.ViewId a)

instance Binary Block.SchemaId where
    put (Block.SchemaId a) = put a
    get = get >>= \a -> return (Block.SchemaId a)

instance Binary Block.Block where
    put (Block.Block a b c d e) = put_version 0
        >> put a >> put b >> put c >> put d >> put e
    get = do
        v <- get_version
        case v of
            0 -> get >>= \a -> get >>= \b -> get >>= \c -> get >>= \d ->
                get >>= \e -> return (Block.Block a b c d e)
            _ -> version_error "Block.Block" v

instance Binary Block.Config where
    put (Block.Config a b c d) = put a >> put b >> put c >> put d
    get = get >>= \a -> get >>= \b -> get >>= \c -> get >>= \d ->
        return (Block.Config a b c d)

instance Binary Block.TracklikeId where
    put (Block.TId a b) = putWord8 0 >> put a >> put b
    put (Block.RId a) = putWord8 1 >> put a
    put (Block.DId a) = putWord8 2 >> put a
    get = do
        tag_ <- getWord8
        case tag_ of
            0 -> get >>= \a -> get >>= \b -> return (Block.TId a b)
            1 -> get >>= \a -> return (Block.RId a)
            2 -> get >>= \a -> return (Block.DId a)
            _ -> fail "no parse for Block.TracklikeId"

instance Binary Block.Divider where
    put (Block.Divider a) = put a
    get = get >>= \a -> return (Block.Divider a)

instance Binary Block.View where
    put (Block.View a b c d e f g h) = put_version 0
        >> put a >> put b >> put c >> put d >> put e >> put f >> put g >> put h
    get = do
        v <- get_version
        case v of
            0 -> get >>= \a -> get >>= \b -> get >>= \c -> get >>= \d ->
                get >>= \e -> get >>= \f -> get >>= \g -> get >>= \h ->
                return (Block.View a b c d e f g h)
            _ -> version_error "Block.View" v

instance Binary Block.TrackView where
    put (Block.TrackView a) = put a
    get = get >>= \a -> return (Block.TrackView a)

instance Binary Block.Rect where
    put (Block.Rect a b) = put a >> put b
    get = get >>= \a -> get >>= \b -> return (Block.Rect a b)

instance Binary Block.ViewConfig where
    put (Block.ViewConfig a b c d e f) = put a >> put b >> put c >> put d
        >> put e >> put f
    get = get >>= \a -> get >>= \b -> get >>= \c -> get >>= \d -> get >>= \e ->
        get >>= \f -> return (Block.ViewConfig a b c d e f)

instance Binary Block.Zoom where
    put (Block.Zoom a b) = put a >> put b
    get = get >>= \a -> get >>= \b -> return (Block.Zoom a b)

instance Binary Block.Selection where
    put (Block.Selection a b c d) = put a >> put b >> put c >> put d
    get = get >>= \a -> get >>= \b -> get >>= \c -> get >>= \d ->
        return (Block.Selection a b c d)

-- ** Types, Color, Font

instance Binary TrackPos where
    put (TrackPos a) = put a
    get = get >>= \a -> return (TrackPos a)

instance Binary Color.Color where
    put (Color.Color a b c d) = put a >> put b >> put c >> put d
    get = get >>= \a -> get >>= \b -> get >>= \c -> get >>= \d ->
        return (Color.Color a b c d)

instance Binary Font.TextStyle where
    put (Font.TextStyle a b c d) = put a >> put b >> put c >> put d
    get = get >>= \a -> get >>= \b -> get >>= \c -> get >>= \d ->
        return (Font.TextStyle a b c d)

-- TODO store as strings?
instance Binary Font.Font where
    put Font.Helvetica = putWord8 0
    put Font.Times = putWord8 1
    put Font.Courier = putWord8 2
    get = do
        tag_ <- getWord8
        case tag_ of
            0 -> return Font.Helvetica
            1 -> return Font.Times
            2 -> return Font.Courier
            _ -> fail "no parse for Font.Font"

instance Binary Font.FontFace where
    put Font.Bold = putWord8 0
    put Font.Italic = putWord8 1
    get = do
        tag_ <- getWord8
        case tag_ of
            0 -> return Font.Bold
            1 -> return Font.Italic
            _ -> fail "no parse for Font.FontFace"

-- ** Ruler

instance Binary Ruler.RulerId where
    put (Ruler.RulerId a) = put a
    get = get >>= \a -> return (Ruler.RulerId a)

instance Binary Ruler.Ruler where
    put (Ruler.Ruler a b c d e) = put_version 0
        >> put a >> put b >> put c >> put d >> put e
    get = do
        v <- get_version
        case v of
            0 -> get >>= \a -> get >>= \b -> get >>= \c -> get >>= \d ->
                get >>= \e -> return (Ruler.Ruler a b c d e)
            _ -> version_error "Ruler.Ruler" v

instance Binary Ruler.Marklist where
    put (Ruler.Marklist a) = put a
    get = get >>= \a -> return (Ruler.Marklist a)

instance Binary Ruler.Mark where
    put (Ruler.Mark a b c d e f) = put a >> put b >> put c >> put d >> put e
        >> put f
    get = get >>= \a -> get >>= \b -> get >>= \c -> get >>= \d -> get >>= \e ->
        get >>= \f -> return (Ruler.Mark a b c d e f)

-- ** Track

instance Binary Track.TrackId where
    put (Track.TrackId a) = put a
    get = get >>= \a -> return (Track.TrackId a)

instance Binary Track.Track where
    put (Track.Track a b c) = put_version 0 >> put a >> put b >> put c
    get = do
        v <- get_version
        case v of
            0 -> get >>= \a -> get >>= \b -> get >>= \c ->
                return (Track.Track a b c)
            _ -> version_error "Track.Track" v

instance Binary Track.TrackEvents where
    put (Track.TrackEvents a) = put_version 0 >> put a
    get = do
        v <- get_version
        case v of
            0 -> get >>= \a -> return (Track.TrackEvents a)
            _ -> version_error "Track.TrackEvents" v

-- ** Event 

instance Binary Event.Event where
    put (Event.Event a b c d e) = put a >> put b >> put c >> put d >> put e
    get = get >>= \a -> get >>= \b -> get >>= \c -> get >>= \d ->
        get >>= \e -> return (Event.Event a b c d e)

-- ** Midi.Instrument

instance Binary Instrument.Instrument where
    put (Instrument.Instrument a b c d e) = put_version 0
        >> put a >> put b >> put c >> put d >> put e
    get = do
        v <- get_version
        case v of
            0 -> get >>= \a -> get >>= \b -> get >>= \c -> get >>=
                \d -> get >>= \e -> return (Instrument.Instrument a b c d e)
            _ -> version_error "Instrument.Instrument" v

instance Binary Instrument.Config where
    put (Instrument.Config a b) = put_version 0 >> put a >> put b
    get = do
        v <- get_version
        case v of
            0 -> get >>= \a -> get >>= \b -> return (Instrument.Config a b)
            _ -> version_error "Instrument.Config" v

instance Binary Instrument.InitializeInstrument where
    put (Instrument.InitializeMidi a) = putWord8 0 >> put a
    put (Instrument.InitializeMessage a) = putWord8 1 >> put a
    put Instrument.NoInitialization = putWord8 2
    get = do
        tag_ <- getWord8
        case tag_ of
            0 -> get >>= \a -> return (Instrument.InitializeMidi a)
            1 -> get >>= \a -> return (Instrument.InitializeMessage a)
            2 -> return Instrument.NoInitialization
            _ -> fail "no parse for Instrument.InitializeInstrument"

-- ** Midi

instance Binary Midi.ReadDevice where
    put (Midi.ReadDevice a) = put a
    get = get >>= \a -> return (Midi.ReadDevice a)

instance Binary Midi.WriteDevice where
    put (Midi.WriteDevice a) = put a
    get = get >>= \a -> return (Midi.WriteDevice a)

instance Binary Midi.Message where
    put (Midi.ChannelMessage a b) = putWord8 0 >> put a >> put b
    put (Midi.CommonMessage a) = putWord8 1 >> put a
    put (Midi.RealtimeMessage a) = putWord8 2 >> put a
    put (Midi.UnknownMessage a b c) = putWord8 3 >> put a >> put b >> put c
    get = do
        tag_ <- getWord8
        case tag_ of
            0 -> get >>= \a -> get >>= \b -> return (Midi.ChannelMessage a b)
            1 -> get >>= \a -> return (Midi.CommonMessage a)
            2 -> get >>= \a -> return (Midi.RealtimeMessage a)
            3 -> get >>= \a -> get >>= \b -> get >>= \c ->
                return (Midi.UnknownMessage a b c)
            _ -> fail "no parse for Midi.Message"

instance Binary Midi.ChannelMessage where
    put (Midi.NoteOff a b) = putWord8 0 >> put a >> put b
    put (Midi.NoteOn a b) = putWord8 1 >> put a >> put b
    put (Midi.Aftertouch a b) = putWord8 2 >> put a >> put b
    put (Midi.ControlChange a b) = putWord8 3 >> put a >> put b
    put (Midi.ProgramChange a) = putWord8 4 >> put a
    put (Midi.ChannelPressure a) = putWord8 5 >> put a
    put (Midi.PitchBend a) = putWord8 6 >> put a
    put Midi.AllSoundOff = putWord8 7
    put Midi.ResetAllControllers = putWord8 8
    put (Midi.LocalControl a) = putWord8 9 >> put a
    put Midi.AllNotesOff = putWord8 10
    put (Midi.UndefinedChannelMode a b) = putWord8 11 >> put a >> put b
    get = do
        tag_ <- getWord8
        case tag_ of
            0 -> get >>= \a -> get >>= \b -> return (Midi.NoteOff a b)
            1 -> get >>= \a -> get >>= \b -> return (Midi.NoteOn a b)
            2 -> get >>= \a -> get >>= \b -> return (Midi.Aftertouch a b)
            3 -> get >>= \a -> get >>= \b -> return (Midi.ControlChange a b)
            4 -> get >>= \a -> return (Midi.ProgramChange a)
            5 -> get >>= \a -> return (Midi.ChannelPressure a)
            6 -> get >>= \a -> return (Midi.PitchBend a)
            7 -> return Midi.AllSoundOff
            8 -> return Midi.ResetAllControllers
            9 -> get >>= \a -> return (Midi.LocalControl a)
            10 -> return Midi.AllNotesOff
            11 -> get >>= \a -> get >>= \b ->
                return (Midi.UndefinedChannelMode a b)
            _ -> fail "no parse for Midi.ChannelMessage"

instance Binary Midi.CommonMessage where
    put (Midi.SystemExclusive a b) = putWord8 0 >> put a >> put b
    put (Midi.SongPositionPointer a) = putWord8 1 >> put a
    put (Midi.SongSelect a) = putWord8 2 >> put a
    put Midi.TuneRequest = putWord8 3
    put Midi.EOX = putWord8 4
    put (Midi.UndefinedCommon a) = putWord8 5 >> put a
    get = do
        tag_ <- getWord8
        case tag_ of
            0 -> get >>= \a -> get >>= \b -> return (Midi.SystemExclusive a b)
            1 -> get >>= \a -> return (Midi.SongPositionPointer a)
            2 -> get >>= \a -> return (Midi.SongSelect a)
            3 -> return Midi.TuneRequest
            4 -> return Midi.EOX
            5 -> get >>= \a -> return (Midi.UndefinedCommon a)
            _ -> fail "no parse for Midi.CommonMessage"

instance Binary Midi.RealtimeMessage where
    put Midi.TimingClock = putWord8 0
    put Midi.Start = putWord8 1
    put Midi.Continue = putWord8 2
    put Midi.Stop = putWord8 3
    put Midi.ActiveSense = putWord8 4
    put Midi.Reset = putWord8 5
    put (Midi.UndefinedRealtime a) = putWord8 6 >> put a
    get = do
        tag_ <- getWord8
        case tag_ of
            0 -> return Midi.TimingClock
            1 -> return Midi.Start
            2 -> return Midi.Continue
            3 -> return Midi.Stop
            4 -> return Midi.ActiveSense
            5 -> return Midi.Reset
            6 -> get >>= \a -> return (Midi.UndefinedRealtime a)
            _ -> fail "no parse for Midi.RealtimeMessage"

-- ** misc

instance Binary Time.UTCTime where
    put time = put (show time)
    get = get >>= return . read
