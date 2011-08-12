{- | This module implements a Serialize class and serializers for basic types.

    It duplicates a lot from the standard Serialize class, but this one at
    least is under my control.  The other one is not guaranteed to remain
    compatible.  Of course, it's unlikely to change incompatibly and I use it
    myself rather than re-implementing String and Integer encoding, but that's
    the theory anyway.

    At the least it lets me use a direct float encoding rather than hacking
    around the large and buggy default implementation.
-}
module Util.Serialize where
import qualified Data.Array.IArray as IArray
import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import qualified Data.Map as Map
import qualified Data.Serialize as Serialize
import Data.Serialize (Get, getWord8, putWord8)
import qualified Data.Set as Set
import qualified System.IO.Unsafe as Unsafe

import Foreign

import Util.Control


encode :: (Serialize a) => a -> ByteString
encode = Serialize.runPut . put

decode :: (Serialize a) => ByteString -> Either String a
decode = Serialize.runGet get

class Serialize a where
    put :: Serialize.Putter a
    get :: Get a

-- * numeric

instance Serialize Integer where
    put = Serialize.put
    get = Serialize.get

instance Serialize Int where
    put i = put (fromIntegral i :: Int64)
    get = fromIntegral <$> (get :: Get Int64)

instance Serialize Int64 where
    put i = put (fromIntegral i :: Word64)
    get = fromIntegral <$> (get :: Get Word64)

instance Serialize Word8 where
    put = putWord8
    get = getWord8

instance Serialize Word32 where
    put = Serialize.putWord32le
    get = Serialize.getWord32le

instance Serialize Word64 where
    put = Serialize.putWord64le
    get = Serialize.getWord64le

instance Serialize Double where
    put = put . encode_double
    get = decode_double <$> get

instance Serialize Float where
    put = put . encode_float
    get = decode_float <$> get

encode_double :: Double -> Word64
encode_double = _encodef

encode_float :: Float -> Word32
encode_float = _encodef

_encodef :: (Storable float, Storable word) => float -> word
_encodef d = Unsafe.unsafePerformIO $ alloca $ \buf -> do
    poke (castPtr buf) d
    peek buf

decode_double :: Word64 -> Double
decode_double = _decodef

decode_float :: Word32 -> Float
decode_float = _decodef

_decodef :: (Storable float, Storable word) => word -> float
_decodef word = Unsafe.unsafePerformIO $ alloca $ \buf -> do
    poke (castPtr buf) word
    peek buf

-- * basic types

instance Serialize () where
    put () = return ()
    get = return ()

instance Serialize Bool where
    put False = putWord8 0
    put True = putWord8 1
    get = do
        b <- getWord8
        return $ if b == 0 then False else True

instance Serialize Char where
    put = Serialize.put
    get = Serialize.get

-- * tuples

instance (Serialize a, Serialize b) => Serialize (a, b) where
    put (a, b) = put a >> put b
    get = (,) <$> get <*> get

instance (Serialize a, Serialize b, Serialize c) => Serialize (a, b, c) where
    put (a, b, c) = put a >> put b >> put c
    get = (,,) <$> get <*> get <*> get

-- * containers

instance (Serialize a) => Serialize [a] where
    put = Serialize.putListOf put
    get = Serialize.getListOf get

instance (Serialize a) => Serialize (Maybe a) where
    put Nothing = putWord8 0
    put (Just a) = putWord8 1 >> put a
    get = do
        tag <- getWord8
        if tag == 0 then return Nothing else Just <$> get

instance (Ord a, Serialize a) => Serialize (Set.Set a) where
    put = put . Set.toAscList
    get = Set.fromAscList <$> get

instance (Ord k, Serialize k, Serialize v) => Serialize (Map.Map k v) where
    put = put . Map.toAscList
    get = Map.fromAscList <$> get

instance (Serialize i, IArray.Ix i, Serialize e) =>
        Serialize (IArray.Array i e) where
    put = Serialize.putIArrayOf put put
    get = Serialize.getIArrayOf get get

instance Serialize ByteString where
    put bs = do
        put (ByteString.length bs)
        Serialize.putByteString bs
    get = get >>= Serialize.getByteString
