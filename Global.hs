-- Copyright 2014 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE CPP #-}
-- | A local Prelude, meant to be imported unqualified.
module Global (
    Proxy(..), Map, Set
    , (<|>)
    , first, second, bimap
    , Monoid(..), Semigroup(..)
    , while, while_
    , whenM, unlessM, whenJust, whenJustM, ifM, andM, orM, findM
    , allM, anyM
    -- * list
    , foldl'
    , mconcatMap, concatMapM, mapMaybeM
    , mapMaybe, fromMaybe

    -- * error
    , justm, rightm
    , firstJust, firstJusts
    , errorStack, errorIO
    , justErr, tryJust, tryRight
    -- * pretty
    , Pretty, pretty, prettys

    -- * lens
    , Lens, (#)
    -- * pure
    , (#$), (#=), (%=)
    -- * state
    , (<#>)
    , module Control.Monad
    , module Data.Traversable
    , module Data.Foldable
    , lift, liftIO
    -- * nonempty
    , module Data.List.NonEmpty
    -- * text
    , Text.Text
    , txt, untxt, showt
) where
import Control.Applicative ((<|>))
import Control.Monad
       ((<=<), (>=>), ap, filterM, foldM, forM, forM_, forever, guard,
        liftM, mplus, msum, mzero, replicateM, replicateM_, when, unless, void,
        zipWithM, zipWithM_)
import Control.Monad.Trans (lift, liftIO)
import Data.Proxy (Proxy(..))

import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty(..))
import Data.Map (Map)
import Data.Set (Set)
import Data.Maybe (mapMaybe, fromMaybe)
import Data.Semigroup (Semigroup(..))
import qualified Data.Text as Text
import Data.Traversable (Traversable, traverse)
import Data.Foldable (Foldable, foldMap)

import Util.Lens
import Util.Pretty (Pretty, pretty, prettys)
import Util.Control


-- | Utilities to make it easier to convert things to Text.  These are
-- intentionally missing the e to make it easier to search for them.
txt :: String -> Text.Text
txt = Text.pack

untxt :: Text.Text -> String
untxt = Text.unpack

showt :: Show a => a -> Text.Text
showt = txt . show
