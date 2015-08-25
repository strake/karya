-- Copyright 2014 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Utilities for scale tests.
module Derive.Scale.ScaleTest where
import qualified Data.List as List

import qualified Derive.Env as Env
import qualified Derive.EnvKey as EnvKey
import qualified Derive.Scale as Scale

import qualified Perform.Pitch as Pitch
import Global


key_environ :: Text -> Env.Environ
key_environ key = Env.insert_val EnvKey.key key mempty

get_scale :: [Scale.Make] -> Text -> Scale.Scale
get_scale scales scale_id = fromMaybe (error $ "no scale: " ++ show scale_id) $
    List.find ((== Pitch.ScaleId scale_id) . Scale.scale_id)
        [scale | Scale.Simple scale <- scales]
