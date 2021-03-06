-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE ScopedTypeVariables #-}
module Util.Crc32Instances where
import qualified Data.ByteString.Unsafe as ByteString.Unsafe
import Data.Digest.CRC32
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Foldable as Foldable
import qualified Data.Int as Int
import qualified Data.List as List
import qualified Data.Text as Text
import qualified Data.Word as Word

import qualified Foreign
import qualified System.IO.Unsafe as Unsafe


instance CRC32 a => CRC32 [a] where crc32Update = List.foldl' crc32Update
instance (CRC32 a, CRC32 b) => CRC32 (a, b) where
    crc32Update n (a, b) = n `crc32Update` a `crc32Update` b
instance (CRC32 a, CRC32 b, CRC32 c) => CRC32 (a, b, c) where
    crc32Update n (a, b, c) = n `crc32Update` a `crc32Update` b `crc32Update` c

instance (CRC32 a, CRC32 b) => CRC32 (Map.Map a b) where
    crc32Update = Foldable.foldl' crc32Update
instance CRC32 a => CRC32 (Set.Set a) where
    crc32Update = Foldable.foldl' crc32Update

instance CRC32 Bool where crc32Update n = crc32Update n . fromEnum
instance CRC32 Char where crc32Update n = crc32Update n . fromEnum

instance CRC32 Int where crc32Update = storable
instance CRC32 Word.Word8 where crc32Update = storable
instance CRC32 Word.Word16 where crc32Update = storable
instance CRC32 Word.Word32 where crc32Update = storable
instance CRC32 Word.Word64 where crc32Update = storable
instance CRC32 Int.Int8 where crc32Update = storable
instance CRC32 Int.Int16 where crc32Update = storable
instance CRC32 Int.Int32 where crc32Update = storable
instance CRC32 Int.Int64 where crc32Update = storable
instance CRC32 Double where crc32Update = storable
instance CRC32 Float where crc32Update = storable

instance CRC32 Text.Text where crc32Update = Text.foldl' crc32Update

storable :: forall a. Foreign.Storable a => Word.Word32 -> a -> Word.Word32
storable n d = Unsafe.unsafePerformIO $ Foreign.alloca $ \ptr -> do
    Foreign.poke ptr d
    ptrIO n ptr 1

ptr :: Foreign.Storable a => Word.Word32 -> Foreign.Ptr a -> Int -> Word.Word32
ptr n ptr len = Unsafe.unsafePerformIO $ ptrIO n ptr len

ptrIO :: forall a. Foreign.Storable a => Word.Word32 -> Foreign.Ptr a -> Int
    -> IO Word.Word32
ptrIO n ptr len =
    crc32Update n <$>
        ByteString.Unsafe.unsafePackCStringLen
            (Foreign.castPtr ptr, len * Foreign.sizeOf val)
    where val = error "Crc32Instances.sizeOf" :: a
