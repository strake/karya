-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.Sig_test where
import Util.Control
import Util.Test
import qualified Ui.State as State
import qualified Derive.Derive as Derive
import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.Sig as Sig
import qualified Derive.TrackLang as TrackLang


test_type_error = do
    let ints :: Sig.Parser [Int]
        ints = Sig.many "ints" ""
        int_sym :: Sig.Parser (Int, TrackLang.Symbol)
        int_sym = (,) <$> Sig.required "int" "" <*> Sig.defaulted "sym" "" ""
        str = TrackLang.str "hi"
        int = TrackLang.num 42
    left_like (call ints [str])
        "arg 1/ints: expected Num (integral) but got Symbol: hi"
    left_like (call int_sym [str]) "arg 1/int: expected Num"
    left_like (call int_sym [int, int]) "arg 2/sym: expected Symbol"

test_not_given = do
    let int :: Sig.Parser (Maybe Int)
        int = Sig.optional "int" Nothing ""
        ints :: Sig.Parser [Int]
        ints = Sig.many "ints" ""
    let num = TrackLang.num
    equal (call int []) (Right Nothing)
    equal (call int [num 42]) (Right (Just 42))
    equal (call ((,) <$> int <*> ints) [num 42])
        (Right (Just 42, []))
    equal (call ((,) <$> int <*> ints) [num 42, num 52])
        (Right (Just 42, [52]))
    equal (call ((,) <$> int <*> ints) [TrackLang.VNotGiven, num 52])
        (Right (Nothing, [52]))

call :: Sig.Parser a -> [TrackLang.Val] -> Either String a
call p vals = DeriveTest.eval State.empty $
    run (Sig.call p (\val _args -> return val)) vals

run :: Derive.WithArgDoc (Sig.Generator y a) -> [TrackLang.Val]
    -> Derive.Deriver a
run (f, _) vals = f args
    where
    args = Derive.PassedArgs
        { Derive.passed_vals = vals
        , Derive.passed_call_name = "test-call"
        , Derive.passed_info = Derive.dummy_call_info 0 1 "test"
        }
