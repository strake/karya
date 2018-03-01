-- Copyright 2018 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE DataKinds, KindSignatures #-}
-- | Functions to read and write audio files.  This should be able to read all
-- formats supported by libsndfile.
module Util.Audio.File (
    -- * read
    check, checkA, read, read44k
    -- * write
    , write, wavFormat
) where
import Prelude hiding (read)
import qualified Control.Exception as Exception
import Control.Monad.Trans (liftIO, lift)
import qualified Control.Monad.Trans.Resource as Resource

import Data.Proxy (Proxy(..))
import Control.Monad.Extra (whenJust)
import qualified GHC.TypeLits as TypeLits
import qualified Sound.File.Sndfile as Sndfile
import qualified Sound.File.Sndfile.Buffer.Vector as Sndfile.Buffer.Vector
import qualified Streaming.Prelude as S
import qualified System.IO.Error as IO.Error

import qualified Util.Audio.Audio as Audio


-- | Check if rate and channels match the file.
check :: forall rate channels.
    (TypeLits.KnownNat rate, TypeLits.KnownNat channels) =>
    Proxy rate -> Proxy channels -> FilePath -> IO (Maybe String)
check rate channels fname = checkInfo rate channels <$> getInfo fname

-- | Like 'check', but take AudioM instead of Proxy.
checkA :: forall m rate channels.
    (TypeLits.KnownNat rate, TypeLits.KnownNat channels) =>
    Proxy (Audio.AudioM m rate channels) -> FilePath -> IO (Maybe String)
checkA _ = check (Proxy :: Proxy rate) (Proxy :: Proxy channels)

getInfo :: FilePath -> IO Sndfile.Info
getInfo fname = Exception.bracket (openRead fname) Sndfile.hClose
    (return . Sndfile.hInfo)

-- | Since the file is opened only when samples are demanded, a sample rate or
-- channels mismatch will turn into an exception then, not when this is called.
read :: forall rate channels.
    (TypeLits.KnownNat rate, TypeLits.KnownNat channels) =>
    FilePath -> Audio.AudioIO rate channels
read fname = Audio.Audio $ do
    (key, handle) <- lift $ Resource.allocate (openRead fname) Sndfile.hClose
    liftIO $ whenJust (checkInfo (Proxy :: Proxy rate) (Proxy :: Proxy channels)
            (Sndfile.hInfo handle)) $ \err ->
        Exception.throwIO $ IO.Error.mkIOError IO.Error.userErrorType err
            Nothing (Just fname)
    let loop = liftIO (Sndfile.hGetBuffer handle Audio.chunkSize) >>= \case
            Nothing -> lift (Resource.release key) >> return ()
            Just buf -> do
                S.yield $ Audio.Chunk $ Sndfile.Buffer.Vector.fromBuffer buf
                loop
    loop

read44k :: FilePath -> Audio.AudioIO 44100 2
read44k = read

checkInfo :: forall rate channels.
    (TypeLits.KnownNat rate, TypeLits.KnownNat channels)
    => Proxy rate -> Proxy channels -> Sndfile.Info -> Maybe String
checkInfo rate_ channels_ info
    | int (Sndfile.samplerate info) == rate
            && int (Sndfile.channels info) == channels = Nothing
    | otherwise = Just $
        "(rate, channels) " ++ show (rate, channels) ++ " /= "
            ++ show (Sndfile.samplerate info, Sndfile.channels info)
    where
    int = fromIntegral
    rate = TypeLits.natVal rate_
    channels = TypeLits.natVal channels_

openRead :: FilePath -> IO Sndfile.Handle
openRead fname = Sndfile.openFile fname Sndfile.ReadMode Sndfile.defaultInfo

-- * write

write :: forall rate channels.
    (TypeLits.KnownNat rate, TypeLits.KnownNat channels)
    => FilePath -> Sndfile.Format -> Audio.AudioIO rate channels
    -> Resource.ResourceT IO ()
write fname format (Audio.Audio audio) = do
    let info = Sndfile.defaultInfo
            { Sndfile.samplerate = fromIntegral $
                TypeLits.natVal (Proxy :: Proxy rate)
            , Sndfile.channels = fromIntegral $
                TypeLits.natVal (Proxy :: Proxy channels)
            , Sndfile.format = format
            }
    (key, handle) <- Resource.allocate
        (Sndfile.openFile fname Sndfile.WriteMode info)
        Sndfile.hClose
    S.mapM_ (liftIO . Sndfile.hPutBuffer handle
            . Sndfile.Buffer.Vector.toBuffer . Audio.chunkSamples)
        audio
    -- loop audio handle
    Resource.release key
    -- where
    -- loop audio handle = S.next audio >>= \case
    --     Left () -> return ()
    --     Right (chunk, audio) -> do
    --         liftIO $ Sndfile.hPutBuffer handle (Sndfile.Buffer.Vector.toBuffer chunk)
    --         loop audio handle

wavFormat :: Sndfile.Format
wavFormat = Sndfile.Format
    { headerFormat = Sndfile.HeaderFormatWav
    , sampleFormat = Sndfile.SampleFormatFloat
    , endianFormat = Sndfile.EndianFile
    }