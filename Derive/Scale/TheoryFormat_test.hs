-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.Scale.TheoryFormat_test where
import Util.Test
import qualified Derive.Scale.Theory as Theory
import qualified Derive.Scale.TheoryFormat as TheoryFormat
import qualified Derive.Scale.Twelve as Twelve

import qualified Perform.Pitch as Pitch


test_show_note = do
    let f fmt key = TheoryFormat.show_note fmt (Just (Pitch.Key key))
        rel = TheoryFormat.sargam Twelve.relative_fmt
    equal (f rel "f#-min" (Theory.Note 3 1)) "s"
    equal (f rel "f#-min" (Theory.Note 4 0)) "rb"
    equal (f rel "f#-min" (Theory.Note 5 0)) "g"