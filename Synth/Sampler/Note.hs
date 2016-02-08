-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE DeriveGeneric, GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
-- | The 'Note' type and support.
module Synth.Sampler.Note where
import qualified Data.Aeson as Aeson
import qualified Data.Map.Strict as Map
import qualified Data.String as String

import qualified GHC.Generics as Generics

import qualified Util.Serialize as Serialize
import Util.Serialize (get, put)
import qualified Perform.Pitch as Pitch
import Global
import qualified Synth.Sampler.Patch as Patch
import qualified Synth.Sampler.Signal as Signal
import Synth.Sampler.Types


-- | High level representation of one note.  This will be converted into
-- one or more 'Sample.Sample's.
data Note = Note {
    instrument :: !Patch.Name
    , start :: !Time
    -- | E.g. envelope, pitch, lpf.
    , controls :: !(Map.Map Control Signal.Signal)
    , attributes :: !Patch.Attributes
    } deriving (Show, Generics.Generic)

instance Aeson.ToJSON Note
instance Aeson.FromJSON Note

instance Serialize.Serialize Note where
    put (Note a b c d) = put a *> put b *> put c *> put d
    get = Note <$> get <*> get <*> get <*> get

note :: Patch.Name -> Time -> Note
note inst start = Note inst start mempty mempty

newtype Control = Control Text
    deriving (Eq, Ord, Show, String.IsString, Aeson.ToJSON, Aeson.FromJSON,
        Serialize.Serialize)

instance Aeson.ToJSON a => Aeson.ToJSON (Map.Map Control a) where
    toJSON = Aeson.toJSON . Map.fromAscList . map (first (\(Control a) -> a))
        . Map.toAscList
instance Aeson.FromJSON a => Aeson.FromJSON (Map.Map Control a) where
    parseJSON = fmap (Map.fromAscList . map (first Control) . Map.toAscList)
        . Aeson.parseJSON

initialControl :: Control -> Note -> Maybe Signal.Y
initialControl control note =
    Signal.at (start note) <$> Map.lookup control (controls note)

initialPitch :: Note -> Maybe Pitch.NoteNumber
initialPitch = fmap Pitch.nn . initialControl pitch

-- * controls

envelope :: Control
envelope = "envelope"

pitch :: Control
pitch = "pitch"