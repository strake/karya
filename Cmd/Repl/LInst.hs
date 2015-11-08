-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE NoMonomorphismRestriction #-}
-- | REPL Cmds dealing with instruments and MIDI config.
module Cmd.Repl.LInst where
import Prelude hiding (lookup)
import qualified Data.ByteString as ByteString
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Text as Text

import qualified Util.Lens as Lens
import qualified Util.Log as Log
import qualified Util.Seq as Seq

import qualified Midi.Interface as Interface
import qualified Midi.Midi as Midi
import qualified Ui.State as State
import qualified Ui.TrackTree as TrackTree
import qualified Cmd.Cmd as Cmd
import qualified Cmd.Info as Info
import qualified Cmd.Instrument.MidiConfig as MidiConfig
import qualified Cmd.Repl.Util as Util
import qualified Cmd.Save as Save

import qualified Derive.Env as Env
import qualified Derive.ParseTitle as ParseTitle
import qualified Derive.RestrictedEnviron as RestrictedEnviron
import qualified Derive.Score as Score
import qualified Derive.ShowVal as ShowVal

import qualified Perform.Midi.Instrument as Instrument
import qualified Perform.Pitch as Pitch
import qualified Instrument.MidiDb as MidiDb
import Global
import Types


-- * instrument info

lookup :: Instrument -> Cmd.CmdL (Maybe Cmd.MidiInfo)
lookup = Cmd.lookup_instrument . Util.instrument

info :: Instrument -> Cmd.CmdL Text
info = Info.inst_info . Util.instrument

info_all :: Cmd.CmdL Text
info_all = do
    config <- State.get_midi_config
    info <- mapM Info.inst_info (Map.keys config)
    return $ showt (length info) <> " instruments:\n"
        <> Text.intercalate "\n" info

-- * config

-- | Print out instrument configs all purty-like.
list :: State.M m => m Text
list = do
    config <- State.get_midi_config
    alias_map <- aliases
    return $ Text.intercalate "\n" $
        map (show_config alias_map) (Map.toList config)
    where
    show_config alias_map (inst, config) = ShowVal.show_val inst <> " - "
        <> Info.show_addrs (map fst (Instrument.config_addrs config))
        <> show_alias alias_map inst
        <> show_controls (Instrument.config_controls config)
        <> show_environ (Instrument.config_restricted_environ config)
        <> show_flags config
    show_alias alias_map inst = case Map.lookup inst alias_map of
        Nothing -> ""
        Just source -> " (source: " <> ShowVal.show_val source <> ")"
    show_controls controls
        | Map.null controls = ""
        | otherwise = " " <> pretty controls
    show_environ environ
        | environ == mempty = ""
        | otherwise = " " <> pretty environ
    show_flags config
        | null flags = ""
        | otherwise = " {" <> Text.intercalate ", " flags <> "}"
        where
        flags = ["mute" | Instrument.config_mute config]
            ++ ["solo" | Instrument.config_solo config]

-- | The not-so-purty version.
midi_config :: State.M m => m Instrument.Configs
midi_config = State.get_midi_config

-- | Alias map.  It maps from alias to underlying instrument.
aliases :: State.M m => m (Map.Map Score.Instrument Score.Instrument)
aliases = State.config#State.aliases <#> State.get

-- | Rename an instrument, in both aliases and allocations.
rename :: State.M m => Instrument -> Instrument -> m ()
rename from_ to_ =
    State.modify $ (State.config#State.midi %= rename_alloc)
        . (State.config#State.aliases %= rename_alias)
    where
    rename_alloc configs = case Map.lookup from configs of
        Nothing -> configs
        Just config -> Map.insert to config $ Map.delete from configs
    rename_alias aliases = case Map.lookup from aliases of
        Just source -> Map.insert to source $ Map.delete from aliases
        Nothing -> aliases
    from = Util.instrument from_
    to = Util.instrument to_

-- | Allocate a new instrument and create an alias for it.  For instance:
--
-- > LInst.add \"m\" \"kontakt/mridangam-g\" \"loop1\" [0]
--
-- This will create an instance of the @kontakt/mridangam@ instrument aliased
-- to @>m@, and assign it to the MIDI WriteDevice @loop1@, with a single MIDI
-- channel 0 allocated.
add :: Instrument -> Instrument -> Text -> [Midi.Channel] -> Cmd.CmdL ()
add alias inst wdev chans = do
    alloc alias wdev chans
    add_alias alias inst

save :: FilePath -> Cmd.CmdL ()
save = Save.save_midi_config

load :: FilePath -> Cmd.CmdL ()
load = Save.load_midi_config

-- | Create an instrument with no channel allocation.  This is used for
-- instruments which are expected to be converted into other instruments during
-- derivation.  For instance, pasang instruments are stand-ins for polos
-- sangsih pairs.
add_empty :: Instrument -> Instrument -> Cmd.CmdL ()
add_empty alias inst = add alias inst "empty" []

-- | Remove both an alias and its allocation.
remove :: Instrument -> Cmd.CmdL ()
remove alias = do
    remove_alias alias
    dealloc alias

-- | Add a new instrument, copied from an existing one.  The argument order is
-- the same as used by 'add'.
add_alias :: Instrument -> Instrument -> Cmd.CmdL ()
add_alias alias inst = State.modify $
    State.config#State.aliases %= Map.insert (Util.instrument alias)
        (Util.instrument inst)

remove_alias :: Instrument -> Cmd.CmdL ()
remove_alias alias = State.modify $
    State.config#State.aliases %= Map.delete (Util.instrument alias)

-- | Toggle and return the new value.
toggle_mute :: State.M m => Instrument -> m Bool
toggle_mute inst = modify_config inst $ \config ->
    let mute = not $ Instrument.config_mute config
    in (config { Instrument.config_mute = mute }, mute)

-- | Toggle and return the new value.
toggle_solo :: State.M m => Instrument -> m Bool
toggle_solo inst = modify_config inst $ \config ->
    let solo = not $ Instrument.config_solo config
    in (config { Instrument.config_solo = solo }, solo)

-- | Add an environ val to the instrument config.
add_environ :: (RestrictedEnviron.ToVal a, State.M m) => Instrument
    -> Env.Key -> a -> m ()
add_environ inst name val = modify_config_ inst $
    Instrument.cenviron %= (RestrictedEnviron.make [(name, v)] <>)
    where v = RestrictedEnviron.to_val val

-- | Clear the instrument config's environ.  The instrument's built-in environ
-- from 'Instrument.patch_environ' is still present.
clear_environ :: State.M m => Instrument -> m ()
clear_environ inst = modify_config_ inst $ Instrument.cenviron #= mempty

set_scale :: State.M m => Instrument -> Instrument.PatchScale -> m ()
set_scale inst scale = modify_config_ inst $ Instrument.cscale #= Just scale

set_control :: State.M m => Instrument -> Score.Control -> Double -> m ()
set_control inst control val = modify_config_ inst $
    Instrument.controls#Lens.map control #= Just val

set_controls :: State.M m => Instrument -> [(Score.Control, Double)] -> m ()
set_controls inst controls = modify_config_ inst $
    Instrument.controls #= Map.fromList controls

get_controls :: State.M m => m (Map.Map Score.Instrument Score.ControlValMap)
get_controls = Map.map Instrument.config_controls <$> State.get_midi_config

get_config :: State.M m => Score.Instrument -> m Instrument.Config
get_config inst = State.require ("no config for " <> pretty inst)
    . Map.lookup inst =<< State.get_midi_config

modify_config :: State.M m => Instrument
    -> (Instrument.Config -> (Instrument.Config, a)) -> m a
modify_config inst_ modify = do
    let inst = Util.instrument inst_
    config <- get_config inst
    let (new, result) = modify config
    State.modify $ State.config # State.midi # Lens.map inst #= Just new
    return result

modify_config_ :: State.M m => Instrument
    -> (Instrument.Config -> Instrument.Config) -> m ()
modify_config_ inst modify = modify_config inst (\c -> (modify c, ()))


-- * allocate a device and channels

-- | Deallocate the old allocation, and set it to the new one.  Meant for
-- interactive use.
alloc :: Instrument -> Text -> [Midi.Channel] -> Cmd.CmdL ()
alloc inst wdev chans =
    alloc_voices inst wdev (map (flip (,) Nothing) chans)

-- | Like 'alloc', but you can also give maximum voices per channel.
alloc_voices :: Instrument -> Text -> [(Midi.Channel, Maybe Instrument.Voices)]
    -> Cmd.CmdL ()
alloc_voices inst_ wdev chan_voices = do
    let inst = Util.instrument inst_
    dealloc_instrument inst
    let dev = Midi.write_device wdev
    alloc_instrument inst [((dev, c), v) | (c, v) <- chan_voices]

dealloc :: Instrument -> Cmd.CmdL ()
dealloc = dealloc_instrument . Util.instrument

-- | Allocate the given channels for the instrument using its default device.
alloc_default :: Instrument -> [(Midi.Channel, Maybe Instrument.Voices)]
    -> Cmd.CmdL ()
alloc_default inst_ chans = do
    let inst = Util.instrument inst_
    wdev <- maybe (Cmd.throw $ "inst not in db: " <> pretty inst) return
        =<< device_of inst
    alloc_instrument inst [((wdev, c), v) | (c, v) <- chans]

-- | Merge the given configs into the existing one.
merge_config :: State.M m => Instrument.Configs -> m ()
merge_config config = State.modify $ State.config#State.midi %= (config<>)

merge :: State.M m => MidiConfig.Config -> m ()
merge = MidiConfig.merge

-- * rest

-- | Steps to load a new instrument.  All of them are optional, depending on
-- the circumstances.
--
-- - Deallocate address asignments for the old instrument, if one is being
-- replaced.
--
-- - Allocate addresses for the new instrument.
--
-- - Title track with new instrument.
--
-- - Send midi init.
--
-- For example, typing a new instrument in a track title should only complain
-- if there is no allocation, but not necessarily deallocate the replaced
-- instrument or send midi init.
set :: Instrument -> Cmd.CmdL ()
set inst_ = do
    let inst = Util.instrument inst_
    block_id <- Cmd.get_focused_block
    tracknum <- Cmd.abort_unless =<< Cmd.get_insert_tracknum
    track_id <- Cmd.abort_unless =<< State.event_track_at block_id tracknum

    -- Deallocate the old instrument.
    title <- State.get_track_title
        =<< State.get_event_track_at block_id tracknum
    whenJust (ParseTitle.title_to_instrument title) dealloc_instrument

    dev <- Cmd.require ("no device for " <> showt inst) =<< device_of inst
    chan <- find_chan_for dev
    alloc_instrument inst [((dev, chan), Nothing)]

    State.set_track_title track_id (ParseTitle.instrument_to_title inst)
    initialize inst chan
    Log.notice $ "allocating " <> showt (dev, chan) <> " to " <> showt inst


-- ** implementation

-- | Find an unallocated channel on the given device.
find_chan_for :: Midi.WriteDevice -> Cmd.CmdL Midi.Channel
find_chan_for dev = do
    config <- State.get_midi_config
    let addrs = map ((,) dev) [0..15]
        taken = concatMap (map fst . Instrument.config_addrs) (Map.elems config)
    let match = fmap snd $ List.find (not . (`elem` taken)) addrs
    Cmd.require ("couldn't find free channel for " <> showt dev) match

initialize :: Score.Instrument -> Midi.Channel -> Cmd.CmdL ()
initialize inst chan = do
    info <- Cmd.require ("inst not found: " <> showt inst)
        =<< Cmd.lookup_instrument inst
    let init = Instrument.patch_initialize (MidiDb.info_patch info)
    let dev = Instrument.synth_device (MidiDb.info_synth info)
    send_initialization init inst dev chan

send_initialization :: Instrument.InitializePatch
    -> Score.Instrument -> Midi.WriteDevice -> Midi.Channel -> Cmd.CmdL ()
send_initialization init inst dev chan = case init of
    Instrument.InitializeMidi msgs -> do
        Log.notice $ "sending midi init: " <> pretty msgs
        mapM_ (Cmd.midi dev . Midi.set_channel chan) msgs
    Instrument.InitializeMessage msg ->
        -- TODO warn doesn't seem quite right for this...
        Log.warn $ "initialize instrument " <> showt inst <> ": " <> msg
    Instrument.NoInitialization -> return ()

alloc_instrument :: Score.Instrument
    -> [(Instrument.Addr, Maybe Instrument.Voices)] -> Cmd.CmdL ()
alloc_instrument inst addrs = State.modify $
    State.config#State.midi#Lens.map inst
        #= Just (Instrument.voice_config addrs)

dealloc_instrument :: Score.Instrument -> Cmd.CmdL ()
dealloc_instrument inst = State.modify $
    State.config#State.midi#Lens.map inst #= Nothing

block_instruments :: BlockId -> Cmd.CmdL [Score.Instrument]
block_instruments block_id = do
    titles <- fmap (map State.track_title) (TrackTree.tracks_of block_id)
    return $ mapMaybe ParseTitle.title_to_instrument titles

-- | Try to automatically create an instrument config based on the instruments
-- found in the given block.  It simply gives each instrument on a device a
-- single channel increasing from 0.
--
-- Example: @auto_config (bid \"b0\") >>= State.set_midi_config@
--
-- TODO: won't work if there are >1 block, need a merge config
-- TODO: same inst with different keyswitches should get the same addrs
auto_config :: BlockId -> Cmd.CmdL Instrument.Configs
auto_config block_id = do
    insts <- block_instruments block_id
    devs <- mapM device_of insts
    let no_dev = [inst | (inst, Nothing) <- zip insts devs]
        inst_devs = [(inst, dev) | (inst, Just dev) <- zip insts devs]
        addrs =
            [ (inst, [(dev, fromIntegral i)])
            | (dev, by_dev) <- Seq.keyed_group_sort snd inst_devs
            , (i, (inst, _dev)) <- Seq.enumerate by_dev
            ]
    unless (null no_dev) $
        Log.warn $ "no synth or midi device found for instruments: "
            <> showt no_dev
    return $ Instrument.configs addrs

device_of :: Score.Instrument -> Cmd.CmdL (Maybe Midi.WriteDevice)
device_of inst = do
    maybe_info <- Cmd.lookup_instrument inst
    return $ Instrument.synth_device . MidiDb.info_synth <$> maybe_info


-- * tuning

-- | Set the instrument's PatchScale to the given scale and send a MIDI tuning
-- message to retune the synth.  Obviously this only works for synths that
-- support it.
retune :: Cmd.M m => Instrument -> [Pitch.NoteNumber] -> m ()
retune inst scale = do
    (msg, keys) <- Cmd.require_right id $ Midi.realtime_tuning $
        Midi.tuning $ map Pitch.nn_to_double scale
    set_scale inst $ Instrument.make_patch_scale "name"
        (Map.toList (Pitch.nn <$> keys))
    devs <- map (fst . fst) . Instrument.config_addrs <$>
        get_config (Util.instrument inst)
    mapM_ (flip Cmd.midi msg) (Seq.unique devs)

-- * midi interface

-- | Every read device on the system, along with any aliases it may have.
read_devices :: Cmd.CmdL [(Midi.ReadDevice, [Midi.ReadDevice])]
read_devices = run_interface Interface.read_devices

-- | Every write device on the system, along with any aliases it may have.
write_devices :: Cmd.CmdL [(Midi.WriteDevice, [Midi.WriteDevice])]
write_devices = run_interface Interface.write_devices

connect_read_device :: Midi.ReadDevice -> Cmd.CmdL Bool
connect_read_device rdev =
    run_interface (flip Interface.connect_read_device rdev)

disconnect_read_device :: Midi.ReadDevice -> Cmd.CmdL Bool
disconnect_read_device rdev =
    run_interface (flip Interface.disconnect_read_device rdev)

run_interface :: (Interface.Interface -> IO a) -> Cmd.CmdL a
run_interface op = do
    interface <- Cmd.gets (Cmd.state_midi_interface . Cmd.state_config)
    liftIO (op interface)


-- * misc

-- | Send a CC MIDI message on the given device.  This is for synths that use
-- MIDI learn.
teach :: Text -> Midi.Channel -> Midi.Control -> Cmd.CmdL ()
teach dev chan cc = Cmd.midi (Midi.write_device dev) $
    Midi.ChannelMessage chan (Midi.ControlChange cc 1)

type Instrument = Text
