-- Copyright 2018 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE DataKinds, KindSignatures #-}
module Util.Audio.File_test where
import qualified Control.Monad.Trans.Resource as Resource
import qualified GHC.TypeLits as TypeLits

import qualified Util.Audio.Audio as Audio
import qualified Util.Audio.File as File
import Global


t_mix out = write out $ Audio.mix $ map (first Audio.Seconds)
    [ (0, File.read44k "g1.wav")
    , (0.5, File.read44k "g1.wav")
    ]

t_sine = write "sine.wav" $ Audio.sine (Audio.Seconds 1) 440

t_multiply = write "multiply.wav" $ Audio.multiply
    (Audio.mergeChannels
        (Audio.linear [(0, 0), (1, 1), (3, 0)])
        (Audio.linear [(0, 0), (1, 1), (2, 0)]))
    (File.read44k "test.wav")

copy :: FilePath -> FilePath -> IO ()
copy input output = write output $ File.read44k input

write :: TypeLits.KnownNat chan => FilePath -> Audio.AudioIO 44100 chan -> IO ()
write fname = Resource.runResourceT . File.write File.wavFormat fname