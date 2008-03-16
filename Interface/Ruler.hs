{-# OPTIONS_GHC -XBangPatterns #-}
module Interface.Ruler (
    Ruler, Config(..), Marklist(..), Mark(..)
    , create
) where

import Interface.Ui (send_action)
import qualified Interface.RulerImpl as R
import Interface.RulerImpl (Ruler, Config(..), Marklist(..), Mark(..))

force = id

create = R.create
