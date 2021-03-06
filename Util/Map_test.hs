-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Util.Map_test where
import qualified Data.Map as Map
import qualified Util.Map as Map
import Util.Test


test_unique_unions = do
    let f = (\(m1, m2) -> (Map.toList m1, Map.toList m2))
            . Map.unique_unions . map Map.fromList
    equal (f [[('a', 1)], [('a', 2)]])
        ([('a', 1)], [('a', 2)])
    equal (f [[('a', 1)], [('a', 2)], [('a', 3)]])
        ([('a', 1)], [('a', 2)])
    equal (f [[('a', 1), ('b', 2)], [('a', 2)]])
        ([('a', 1), ('b', 2)], [('a', 2)])
