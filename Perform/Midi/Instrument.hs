-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{- | Description of a midi-specific instrument, as well as the runtime midi
    device and channel mapping.

    This is all a little too complicated.

    The complete description for a set of instruments is a 'MidiDb.SynthDesc'.
    This is just a ('Synth', PatchMap) pair, and a PatchMap is a map from
    instrument name to 'Patch'.  A Patch contains an 'Instrument', which is the
    subset of data needed for performance.  Since there is a separate
    Instrument per keyswitch, multiple Instruments may be generated from
    a single Patch.  Patches also inherit some information from their Synth.
    So the hierarchy, from general to specific, goes
    @'Synth' -> 'Patch' -> 'Instrument'@.

    Creation of a SynthDesc is a little complicated because of the
    inter-relationships between the types.  A Patch is created with an
    Instrument as a template, but the template Instrument also wants know
    the synth name for error reporting, so those should be kept in sync.
-}
module Perform.Midi.Instrument (
    module Perform.Midi.Instrument, Control.PbRange
) where
import qualified Control.DeepSeq as DeepSeq
import Control.DeepSeq
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Set as Set
import qualified Data.Vector.Unboxed as Vector

import qualified Util.Lens as Lens
import qualified Util.Num as Num
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq
import qualified Util.Vector

import qualified Midi.Midi as Midi
import qualified Derive.RestrictedEnviron as RestrictedEnviron
import qualified Derive.Score as Score
import qualified Derive.ShowVal as ShowVal
import qualified Derive.BaseTypes as BaseTypes

import qualified Perform.Midi.Control as Control
import qualified Perform.Pitch as Pitch
import Global
import Types


-- * instrument

-- | The Instrument contains all the data necessary to render
-- a 'Perform.Midi.Perform.Event' to a midi message.  Each Event has an
-- attached Instrument.
--
-- Don't put data unnecessary to derivation in here because they are compared
-- to each other a lot when trying to merge channels.  All that stuff should go
-- into the 'Patch'.
--
-- TODO if it helps performance, have a separate Perform.Instrument that
-- includes a fingerprint for fast comparison.
data Instrument = Instrument {
    -- | This is the name of the instrument on the synthesizer, and likely has
    -- all sorts of wacky characters in it, and may not be unique, even on
    -- a single synth.
    --
    -- For wildcard patches, the name should be left blank and will be filled
    -- in by however the instrument is looked up.  This doesn't have the synth
    -- on it, so it may not be unique.
    inst_name :: !InstrumentName

    -- | The score name should uniquely identify one instrument, and is
    -- generated by 'Instrument.MidiDb.midi_db' constructor.
    --
    -- 'inst_score', 'inst_synth', and 'inst_keyswitch' are blank in the
    -- 'patch_instrument' template instance and filled in with data from the
    -- Synth and Patch when the instrument is looked up in the db.
    , inst_score :: !Score.Instrument
    , inst_synth :: !SynthName
    , inst_keyswitch :: ![Keyswitch]
    -- | If true, the keysitch has to be held while the note is playing.
    -- Otherwise, it will just be tapped before the note starts.
    , inst_hold_keyswitch :: !Bool

    -- | Map control names to a control number.  Some controls are shared by
    -- all midi instruments, but some instruments have special controls.
    , inst_control_map :: !Control.ControlMap

    , inst_pitch_bend_range :: !Control.PbRange
    -- | Time from NoteOff to inaudible, in seconds.  This can be used to
    -- figure out how long to generate control messages, or possibly determine
    -- overlap for channel allocation, though I use LRU so it shouldn't matter.
    , inst_maybe_decay :: !(Maybe RealTime)
    } deriving (Eq, Ord, Show)

name = Lens.lens inst_name
    (\f r -> r { inst_name = f (inst_name r) })
score = Lens.lens inst_score
    (\f r -> r { inst_score = f (inst_score r) })
synth_ = Lens.lens inst_synth
    (\f r -> r { inst_synth = f (inst_synth r) })
keyswitch = Lens.lens inst_keyswitch
    (\f r -> r { inst_keyswitch = f (inst_keyswitch r) })
hold_keyswitch = Lens.lens inst_hold_keyswitch
    (\f r -> r { inst_hold_keyswitch = f (inst_hold_keyswitch r) })
control_map = Lens.lens inst_control_map
    (\f r -> r { inst_control_map = f (inst_control_map r) })
pitch_bend_range = Lens.lens inst_pitch_bend_range
    (\f r -> r { inst_pitch_bend_range = f (inst_pitch_bend_range r) })
maybe_decay = Lens.lens inst_maybe_decay
    (\f r -> r { inst_maybe_decay = f (inst_maybe_decay r) })


instance NFData Instrument where
    -- don't bother with the rest since instruments are constructed all at once
    rnf inst = rnf (inst_score inst)

instance Pretty.Pretty Instrument where
    format (Instrument name score synth keyswitch hold_keyswitch cmap
            pb_range decay) =
        Pretty.record "Instrument"
            [ ("name", Pretty.format name)
            , ("score", Pretty.format score)
            , ("synth", Pretty.format synth)
            , ("keyswitch", Pretty.format keyswitch)
            , ("hold_keyswitch", Pretty.format hold_keyswitch)
            , ("control_map", Pretty.format cmap)
            , ("pb_range", Pretty.format pb_range)
            , ("decay", Pretty.format decay)
            ]
    -- format inst
    --     -- This is the most accurate since it's been mangled to fit the inst
    --     -- naming conventions, but won't be set if the Instrument is still
    --     -- in the Patch.
    --     | inst_score inst /= Score.empty_inst =
    --         Pretty.format (inst_score inst)
    --     | not (null (inst_name inst)) = Pretty.format (inst_name inst)
    --     -- Otherwise it's a wildcard in the Patch, so it has no name.
    --     | otherwise = Pretty.text "<wildcard>"

-- ** construction

-- These functions are the external interface for creating Instruments.  It's
-- important to have a somewhat abstract interface because lots of instruments
-- are created by hand in the Local.Instrument hierarchy.  If everyone uses the
-- functions in here I can hopefully provide some insulation against changes
-- in the underlying type.

-- | Initialize with values I think just about every instrument will want to
-- set.  The rest can be initialized with set_* functions or lenses.
instrument :: InstrumentName -> [(Midi.Control, Score.Control)]
    -> Control.PbRange -> Instrument
instrument name cmap pb_range = Instrument
    { inst_name = name
    , inst_score = Score.Instrument ""
    , inst_synth = ""
    , inst_keyswitch = []
    , inst_hold_keyswitch = False
    , inst_control_map = Control.control_map cmap
    , inst_pitch_bend_range = pb_range
    , inst_maybe_decay = Nothing
    }

-- | A wildcard instrument has its name automatically filled in, and has no
-- need for controls since they can go in the Synth.
wildcard_instrument :: Control.PbRange -> Instrument
wildcard_instrument = instrument "*" []
    -- The inst name will be replaced, but 'MidiDb.validate' at least can use
    -- the template name when reporting errors.

-- ** defaults

-- | Somewhat conservative default decay which should suit most instruments.
-- 'inst_decay' will probably only rarely be explicitly set.
default_decay :: RealTime
default_decay = 1.0

inst_decay :: Instrument -> RealTime
inst_decay = fromMaybe default_decay . inst_maybe_decay

-- * config

-- | Per-score instrument configuration.
type Configs = Map.Map Score.Instrument Config

configs :: [(Score.Instrument, [Addr])] -> Configs
configs = Map.fromList . map (second config)

voice_configs :: [(Score.Instrument, [(Addr, Maybe Voices)])] -> Configs
voice_configs = Map.fromList . map (second voice_config)

get_addrs :: Score.Instrument -> Configs -> [Addr]
get_addrs inst = maybe [] (map fst . config_addrs) . Map.lookup inst

-- | Configuration for one instrument on a score.
data Config = Config {
    -- | An instrument may have multiple addresses assigned to it, which means
    -- that it can be multiplexed across multiple channels.  In addition,
    -- multiple instruments can be allocated to overlapping addresses, which is
    -- how keyswitches work; each one is considered a separate instrument.  An
    -- instrument wishing to use an address will emit an appropriate message to
    -- configure it (probably a keyswitch, possibly a program change).
    --
    -- Each Addr has a count of how many simultaneous voices the addr can
    -- handle.  Nothing means there's no limit.
    config_addrs :: ![(Addr, Maybe Voices)]
    -- | This is a local version of 'patch_restricted_environ'.
    , config_restricted_environ :: !RestrictedEnviron.Environ
    -- | A local version of 'patch_scale'.
    , config_scale :: !(Maybe PatchScale)
    -- | Default controls for this instrument, will always be set unless
    -- explicitly replaced.  This hopefully avoids the problem where
    -- a synthesizer starts in an undefined state.
    , config_controls :: !Score.ControlValMap
    -- | If true, this instrument is filtered out prior to playing.
    , config_mute :: !Bool
    -- | If any instrument is soloed, all instruments except soloed ones are
    -- filtered out prior to playing.
    , config_solo :: !Bool
    } deriving (Eq, Read, Show)

config_environ :: Config -> BaseTypes.Environ
config_environ = RestrictedEnviron.convert . config_restricted_environ

addrs = Lens.lens config_addrs
    (\f r -> r { config_addrs = f (config_addrs r) })
cenviron = Lens.lens config_restricted_environ
    (\f r -> r { config_restricted_environ = f (config_restricted_environ r) })
cscale = Lens.lens config_scale
    (\f r -> r { config_scale = f (config_scale r) })
controls = Lens.lens config_controls
    (\f r -> r { config_controls = f (config_controls r) })
mute = Lens.lens config_mute
    (\f r -> r { config_mute = f (config_mute r) })
solo = Lens.lens config_solo
    (\f r -> r { config_solo = f (config_solo r) })

config1 :: Midi.WriteDevice -> Midi.Channel -> Config
config1 dev chan = config [(dev, chan)]

config :: [Addr] -> Config
config = voice_config . map (flip (,) Nothing)

voice_config :: [(Addr, Maybe Voices)] -> Config
voice_config addrs = Config
    { config_addrs = addrs
    , config_restricted_environ = mempty
    , config_scale = Nothing
    , config_controls = mempty
    , config_mute = False
    , config_solo = False
    }

instance Pretty.Pretty Config where
    format (Config addrs environ scale controls mute solo) =
            Pretty.record "Config"
        [ ("addrs", Pretty.format addrs)
        , ("environ", Pretty.format environ)
        , ("scale", Pretty.format scale)
        , ("mute", Pretty.format mute)
        , ("controls", Pretty.format controls)
        , ("solo", Pretty.format solo)
        ]

-- | MIDI instruments are addressed by a (device, channel) pair, allocated in
-- 'Config'.
type Addr = (Midi.WriteDevice, Midi.Channel)
-- | Number of simultaneous voices a certain Addr supports, aka polyphony.
type Voices = Int

-- * instrument db types

-- When there are multiple backends, this will have to move to a more general
-- place.

-- | A Patch has information about one specific instrument.  The performance
-- 'Instrument' and MIDI config are derived from it, via its 'Synth'.
data Patch = Patch {
    -- | The Instrument is a subset of the data available in the Patch.
    -- The 'Instrument' is not necessarily the same as the one eventually
    -- used in performance, because e.g. synth controls can get added in.
    patch_instrument :: !Instrument
    , patch_scale :: !(Maybe PatchScale)
    -- | This environ is merged into the derive environ when the instrument
    -- comes into scope, and also when the pitch of 'Score.Event's with this
    -- instrument is converted.  Typically it sets things like instrument
    -- range, tuning details, etc.
    , patch_restricted_environ :: !RestrictedEnviron.Environ
    , patch_flags :: !(Set.Set Flag)
    , patch_initialize :: !InitializePatch
    , patch_attribute_map :: !AttributeMap
    , patch_call_map :: !CallMap
    -- | Key-value pairs used to index the patch.  A key may appear more than
    -- once with different values.  Tags are free-form, but there is a list of
    -- standard tags in "Instrument.Tag".
    , patch_tags :: ![Tag]
    -- | Some free form text about the patch.
    , patch_text :: !Text
    -- | The patch was read from this file.
    , patch_file :: !FilePath
    } deriving (Eq, Show)

instrument_ = Lens.lens patch_instrument
    (\f r -> r { patch_instrument = f (patch_instrument r) })
scale = Lens.lens patch_scale (\f r -> r { patch_scale = f (patch_scale r) })
environ = Lens.lens patch_restricted_environ
    (\f r -> r { patch_restricted_environ = f (patch_restricted_environ r) })
flags = Lens.lens patch_flags
    (\f r -> r { patch_flags = f (patch_flags r) })
initialize = Lens.lens patch_initialize
    (\f r -> r { patch_initialize = f (patch_initialize r) })
attribute_map = Lens.lens patch_attribute_map
    (\f r -> r { patch_attribute_map = f (patch_attribute_map r) })
call_map = Lens.lens patch_call_map
    (\f r -> r { patch_call_map = f (patch_call_map r) })
tags = Lens.lens patch_tags (\f r -> r { patch_tags = f (patch_tags r) })
text = Lens.lens patch_text (\f r -> r { patch_text = f (patch_text r) })
file = Lens.lens patch_file (\f r -> r { patch_file = f (patch_file r) })

patch_environ :: Patch -> BaseTypes.Environ
patch_environ = RestrictedEnviron.convert . patch_restricted_environ

-- | Create a Patch with empty vals, to set them as needed.
patch :: Instrument -> Patch
patch inst = Patch
    { patch_instrument = inst
    , patch_scale = Nothing
    , patch_restricted_environ = mempty
    , patch_flags = Set.empty
    , patch_initialize = NoInitialization
    , patch_attribute_map = AttributeMap []
    , patch_call_map = Map.empty
    , patch_tags = []
    , patch_text = ""
    , patch_file = ""
    }

-- | If a patch is tuned to something other than 12TET, this vector maps MIDI
-- key numbers to their NNs, or 0 if the patch doesn't support that key.
data PatchScale = PatchScale !Text (Vector.Vector Double)
    deriving (Eq, Show, Read)

instance Pretty.Pretty PatchScale where
    pretty (PatchScale name v) = name <> " ("
        <> showt (Util.Vector.count (/=0) v) <> " pitches)"

-- | Fill in non-adjacent MIDI keys by interpolating the neighboring
-- NoteNumbers.  This is because a 0 between two notes will prevent pitch
-- slides.  Another problem is that the MIDI performer has no notion of
-- instruments that don't support certain key numbers.  That could be added
-- but it's simpler to just not have patches like that.
make_patch_scale :: Text -> [(Midi.Key, Pitch.NoteNumber)] -> PatchScale
make_patch_scale name keys =
    PatchScale name (empty Vector.// map convert (interpolate keys))
    where
    convert (k, Pitch.NoteNumber nn) = (Midi.from_key k, nn)
    interpolate ((k1, nn1) : rest@((k2, nn2) : _))
        | k1 + 1 == k2 = (k1, nn1) : interpolate rest
        | otherwise = (k1, nn1) : map mk (Seq.range' (k1+1) k2 1)
            ++ interpolate rest
        where
        mk k = (k, nn)
            where
            nn = Num.scale nn1 nn2 $ Num.normalize
                (Midi.from_key k1) (Midi.from_key k2) (Midi.from_key k)
    interpolate xs = xs
    empty = Vector.fromList $ replicate 128 0

convert_patch_scale :: PatchScale -> Pitch.NoteNumber -> Maybe Pitch.NoteNumber
convert_patch_scale (PatchScale _ scale) (Pitch.NoteNumber nn) =
    case Util.Vector.bracketing scale nn of
        Just (i, low, high) | low /= 0 -> Just $ Pitch.NoteNumber $
            fromIntegral i + Num.normalize low high nn
        _ -> Nothing

-- | A Pretty instance is useful because InitializeMidi tends to be huge.
instance Pretty.Pretty Patch where
    format (Patch inst scale environ flags init attr_map call_map
            tags text file) =
        Pretty.record "Patch"
            [ ("instrument", Pretty.format inst)
            , ("scale", Pretty.format scale)
            , ("environ", Pretty.format environ)
            , ("flags", Pretty.format flags)
            , ("initialize", Pretty.format init)
            , ("attribute_map", Pretty.format attr_map)
            , ("call_map", Pretty.format call_map)
            , ("tags", Pretty.format tags)
            , ("text", Pretty.format text)
            , ("file", Pretty.format file)
            ]

patch_name :: Patch -> InstrumentName
patch_name = inst_name . patch_instrument

set_flag :: Flag -> Patch -> Patch
set_flag flag = flags %= Set.insert flag

unset_flag :: Flag -> Patch -> Patch
unset_flag flag = flags %= Set.delete flag

triggered, pressure :: Patch -> Patch
triggered = set_flag Triggered
pressure = set_flag Pressure

has_flag :: Flag -> Patch -> Bool
has_flag flag = Set.member flag . patch_flags

set_decay :: RealTime -> Patch -> Patch
set_decay secs = instrument_#maybe_decay #= Just secs

-- | Various instrument flags.
data Flag =
    -- | Patch doesn't pay attention to duration.  E.g., drum samples may not
    -- pay attention to note off.  The UI can use this to create zero duration
    -- events for this patch.
    Triggered
    -- | Patch uses continuous pressure control, assigned to CC 2 (breath),
    -- instead of trigger velocity.  This is used to support the @dyn@ control.
    -- Percussive instruments like pianos map it to MIDI velocity, and
    -- continuous instruments like winds always have maximum velocity and map
    -- @dyn@ to breath.
    | Pressure
    -- | Notes on this instrument don't change their pitch after they start.
    -- This suppresses all pitch bending for each note.  It's useful because
    -- it can be difficult to prevent pitch leakage.  E.g. if a transpose
    -- signal starts after the note and the note is moved, it winds up at the
    -- end of the note.
    --
    -- Obviously it's a hack, but it's useful in practice.  It could also go in
    -- the note generator, but it's convenient to apply it in convert because
    -- that's where the transpose signals are applied.
    | ConstantPitch
    deriving (Eq, Ord, Show)

instance Pretty.Pretty Flag where pretty = showt

-- ** attribute map

{- | This determines what Attributes the instrument can respond to.  Each
    set of Attributes is mapped to optional Keyswitches and maybe a Keymap.
    The attributes are matched by subset in order, so their order gives
    a priority.

    For example, if @+pizz@ is before @+cresc@, then @+pizz+cresc@ will map to
    @+pizz@, unless @+pizz+cresc@ comes before either (of course that
    particular combination is unlikely to exist).  So if a previous attr set is
    a subset of a later one, the later one will never be selected.
    'overlapping_attributes' will check for that.
-}
newtype AttributeMap =
    AttributeMap [(Score.Attributes, [Keyswitch], Maybe Keymap)]
    deriving (Eq, Show, Pretty.Pretty, DeepSeq.NFData)

-- | A Keymap corresponds to a timbre selected by MIDI key range, rather than
-- keyswitches.  Unlike a keyswitch, this doesn't change the state of the MIDI
-- channel, so multiple keymapped notes can coexist, and keymap replaces the
-- pitch of the note.
data Keymap =
    -- | This ignores the event's pitch and instead emits the given MIDI key.
    -- This is appropriate for drumkit style patches, with a separate unpitched
    -- timbre on each key.
    UnpitchedKeymap !Midi.Key
    -- | The timbre is mapped over the inclusive MIDI key range from low to
    -- high, where the pitch of the low end of the range is given by the
    -- NoteNumber.  So this transposes the event's pitch and clips it to the
    -- given range.
    | PitchedKeymap !Midi.Key !Midi.Key !Pitch.NoteNumber
    deriving (Eq, Ord, Show)

instance Pretty.Pretty Keymap where
    pretty (UnpitchedKeymap k) = pretty k
    pretty (PitchedKeymap low high nn) = pretty low <> "--"
        <> pretty high <> "(" <> pretty nn <> ")"

-- | A Keyswitch changes the timbre of a patch, but does so in a channel-global
-- way.  So overlapping notes with different keyswitches will be split into
-- different channels, if possible.
data Keyswitch =
    Keyswitch !Midi.Key
    -- | This keyswitch is triggered by a control change.
    | ControlSwitch !Midi.Control !Midi.ControlValue
    deriving (Eq, Ord, Show, Read)

instance DeepSeq.NFData Keymap where
    rnf (UnpitchedKeymap k) = k `seq` ()
    rnf (PitchedKeymap k _ _) = k `seq` ()

instance DeepSeq.NFData Keyswitch where
    rnf (Keyswitch k) = k `seq` ()
    rnf (ControlSwitch k _) = k `seq` ()

instance Pretty.Pretty Keyswitch where
    format (Keyswitch key) = "key:" <> Pretty.format key
    format (ControlSwitch cc val) =
        "cc:" <> Pretty.format cc <> "/" <> Pretty.format val

-- | Look up keyswitches and keymap according to the attribute priorities as
-- described in 'AttributeMap'.
lookup_attribute :: Score.Attributes -> AttributeMap
    -> Maybe ([Keyswitch], Maybe Keymap)
lookup_attribute attrs (AttributeMap table) =
    (\(_, ks, km) -> (ks, km)) <$> List.find is_subset table
    where
    is_subset (inst_attrs, _, _) = Score.attrs_set inst_attrs
        `Set.isSubsetOf` Score.attrs_set attrs

-- | Figured out if any attributes shadow other attributes.  I think this
-- shouldn't happen if you called 'sort_attributes', or used any of the
-- constructors other than 'AttributeMap'.
overlapping_attributes :: AttributeMap -> [Text]
overlapping_attributes attr_map =
    Maybe.catMaybes $ zipWith check (List.inits attrs) attrs
    where
    attrs = mapped_attributes attr_map
    check prevs attr = case List.find (Score.attrs_contain attr) prevs of
        Just other_attr -> Just $ "attrs "
            <> ShowVal.show_val attr <> " shadowed by "
            <> ShowVal.show_val other_attr
        Nothing -> Nothing

make_attribute_map :: [(Score.Attributes, [Keyswitch], Maybe Keymap)]
    -> AttributeMap
make_attribute_map = sort_attributes . AttributeMap

-- | An AttributeMap with just keyswitches.
keyswitches :: [(Score.Attributes, [Keyswitch])] -> AttributeMap
keyswitches attr_ks = sort_attributes $
    AttributeMap [(attrs, ks, Nothing) | (attrs, ks) <- attr_ks]

-- | An AttributeMap with a single Midi.Key keyswitch per Attribute.
simple_keyswitches :: [(Score.Attributes, Midi.Key)] -> AttributeMap
simple_keyswitches = keyswitches . map (second ((:[]) . Keyswitch))

cc_keyswitches :: Midi.Control -> [(Score.Attributes, Midi.ControlValue)]
    -> AttributeMap
cc_keyswitches cc = keyswitches . map (second ((:[]) . ControlSwitch cc))

keymap :: [(Score.Attributes, Keymap)] -> AttributeMap
keymap table = sort_attributes $
    AttributeMap [(attr, [], Just keymap) | (attr, keymap) <- table]

-- | An AttributeMap with just unpitched keymaps.
simple_keymap :: [(Score.Attributes, Midi.Key)] -> AttributeMap
simple_keymap = keymap . map (second UnpitchedKeymap)

mapped_attributes :: AttributeMap -> [Score.Attributes]
mapped_attributes (AttributeMap attrs) = map (\(a, _, _) -> a) attrs

-- | 'lookup_attribute' looks for the first subset, which means that a smaller
-- set of attributes can shadow a larger set.  Since it's annoying to have to
-- worry about order, sort larger sets to the back.
--
-- The sort is stable, so it shouldn't destroy the priority implicit in the
-- order.
sort_attributes :: AttributeMap -> AttributeMap
sort_attributes (AttributeMap table) = AttributeMap (sort table)
    where sort = Seq.sort_on (\(a, _, _) -> - Set.size (Score.attrs_set a))

-- ** misc

-- | Map attributes to the names of the calls they should map to.  This
-- is used by the integrator to turn score events into UI events.
type CallMap = Map.Map Score.Attributes BaseTypes.CallId

type Tag = (TagKey, TagVal)
type TagKey = Text
type TagVal = Text

-- * synth

-- | A Synth defines common features for a set of instruments.  Synths form
-- a global flat namespace and must be unique.
data Synth = Synth {
    -- | Uniquely defines the synth.
    synth_name :: !SynthName
    -- | Full name for the synthesizer.  'synth_name' appears in inst names so
    -- it has a restricted character set.
    , synth_doc :: !Text
    -- | Often synths have a set of common controls in addition to the
    -- global midi defaults.
    , synth_control_map :: !Control.ControlMap
    -- | Set if this synth supports MIDI realtime tuning, as emitted by
    -- 'Midi.realtime_tuning'.  Currently this has no effect, but it's
    -- a useful note.
    , synth_supports_realtime_tuning :: !Bool
        -- If there are ever >1 of these, make it Set SynthFlag.
    } deriving (Eq, Show)

instance Pretty.Pretty Synth where
    format (Synth name doc cmap tuning) = Pretty.record "Synth"
        [ ("name", Pretty.format name)
        , ("doc", Pretty.format doc)
        , ("control_map", Pretty.format cmap)
        , ("supports_realtime_tuning", Pretty.format tuning)
        ]

synth :: SynthName -> Text -> [(Midi.Control, Score.Control)] -> Synth
synth name doc cmap = Synth
    { synth_name = name
    , synth_doc = doc
    , synth_control_map = Control.control_map cmap
    , synth_supports_realtime_tuning = False
    }

-- | Synths default to writing to a device with their name.  You'll have to
-- map it to a real hardware WriteDevice in the 'Cmd.Cmd.write_device_map'.
synth_device :: Synth -> Midi.WriteDevice
synth_device = Midi.write_device . synth_name

type SynthName = Text
type InstrumentName = Text

-- | Describe how an instrument should be initialized before it can be played.
data InitializePatch =
    -- | Send these msgs to initialize the patch.  Should be a patch change or
    -- a sysex.
    InitializeMidi ![Midi.Message]
    -- | Display this msg to the user and hope they do what it says.
    | InitializeMessage !Text
    | NoInitialization
    deriving (Eq, Ord, Show)

instance Pretty.Pretty InitializePatch where
    format (InitializeMidi msgs) =
        Pretty.text "InitializeMidi" Pretty.<+> Pretty.format msgs
    format init = Pretty.text (showt init)

add_tag :: Tag -> Patch -> Patch
add_tag tag = tags %= (tag:)

-- | Constructor for a softsynth with a single wildcard patch.  Used by
-- 'Instrument.MidiDb.softsynth'.
make_softsynth :: SynthName -> Text -> Control.PbRange
    -> [(Midi.Control, Score.Control)] -> (Synth, Patch)
make_softsynth name doc pb_range controls =
    (synth name doc controls, template_patch)
    where template_patch = patch (wildcard_instrument pb_range)
