-- Copyright 2014 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Cmd.Ky_test where
import qualified Data.Text as Text

import Util.Test
import qualified Ui.UiTest as UiTest
import qualified Cmd.Cmd as Cmd
import qualified Cmd.CmdTest as CmdTest
import qualified Cmd.Ky as Ky
import qualified Cmd.PlayUtil as PlayUtil

import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.Parse as Parse
import Global


test_ky_file = do
    let run text tracks = DeriveTest.extract extract $ CmdTest.eval
            (CmdTest.make_tracks tracks) CmdTest.default_cmd_state $
            put_library text >> PlayUtil.uncached_derive UiTest.default_block_id
        extract = DeriveTest.e_attributes
        defs = Text.unlines
            [ "note generator:"
            , "with-a = n +a"
            , "like-n = n"
            , "note transformer:"
            , "d = +a"
            ]
    equal (run defs [(">", [(0, 1, "with-a")])]) (["+a"], [])
    strings_like (snd $ run defs [(">", [(0, 1, "with-a x")])])
        ["too many arguments"]
    -- Args are ok if the definition doesn't have any.
    equal (run defs [(">", [(0, 1, "like-n +a")])]) (["+a"], [])
    -- A local note transformer shadows the built-in 'd' transformer.
    equal (run defs [(">", [(0, 1, "d |")])]) (["+a"], [])

    -- Definitions can be full expressions.
    let defs = Text.unlines
            [ "note generator:"
            , "with-a = +a | n"
            , "note transformer:"
            , "d = +a | +b"
            ]
    equal (run defs [(">", [(0, 1, "with-a")])]) (["+a"], [])
    equal (run defs [(">", [(0, 1, "d |")])]) (["+a+b"], [])

put_library :: Cmd.M m => Text -> m ()
put_library text = Cmd.modify $ \st -> st
    { Cmd.state_ky_cache = Just $ case Parse.parse_ky "fname.ky" text of
        Left err -> Cmd.KyCache (Left err) mempty
        Right (_, defs) ->
            Cmd.KyCache (Right $ Ky.compile_library defs) mempty
    }