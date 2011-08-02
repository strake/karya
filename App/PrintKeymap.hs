module App.PrintKeymap where
import qualified Control.Monad.Identity as Identity
import qualified Data.Char as Char
import qualified Data.Map as Map
import qualified Data.Set as Set

import qualified Text.Printf as Printf

import Util.Control
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq

import qualified Ui.Key as Key
import qualified Cmd.Cmd as Cmd
import qualified Cmd.GlobalKeymap as GlobalKeymap
import qualified Cmd.Keymap as Keymap
import qualified Cmd.NoteTrack as NoteTrack
import qualified Cmd.NoteTrackKeymap as NoteTrackKeymap


main :: IO ()
main = mapM_ putStrLn
    [ "<html> <head> <title> keymaps </title> </head> <body>"
    , html_fmt "global" $ extract GlobalKeymap.all_cmd_map
    , html_fmt "note track" $ extract $ fst $
        NoteTrackKeymap.make_keymap (NoteTrack.CreateTrack 0 0)
    , "</body> </html>"
    ]

type CmdMap = Keymap.CmdMap (Cmd.CmdT Identity.Identity)
type Binds = [(String, [Keymap.KeySpec])]

-- * extract

extract :: CmdMap -> Binds
extract = sort . strip . group . Map.toList

sort :: Binds -> Binds
sort = Seq.sort_on (map key . snd)
    where
    key (Keymap.KeySpec mods bindable) = (bindable_key bindable, mods)
    bindable_key (Keymap.Key is_repeat (Key.Char c)) =
        Keymap.Key is_repeat (Key.Char (Char.toLower c))
    bindable_key k = k

group :: [(Keymap.KeySpec, Keymap.CmdSpec m)] -> [(String, [Keymap.KeySpec])]
group = map (second (map fst)) . Seq.keyed_group_on (name_of . snd)
    where name_of (Keymap.CmdSpec name _) = name

strip :: Binds -> Binds
strip = map (second strip_keyspecs)

-- | A repeatable key implies the non-repeating key.  Also, a drag implies
-- a click.
strip_keyspecs :: [Keymap.KeySpec] -> [Keymap.KeySpec]
strip_keyspecs = map stripm . strip_drag . strip_repeatable
    where
    strip_drag mods
        | any is_drag mods = filter is_drag mods
        | otherwise = mods
    is_drag (Keymap.KeySpec _ (Keymap.Drag _)) = True
    is_drag _ = False
    strip_repeatable mods
        | any is_repeatable mods = filter is_repeatable mods
        | otherwise = mods
    is_repeatable (Keymap.KeySpec _ (Keymap.Key is_repeat _)) = is_repeat
    is_repeatable _ = False
    stripm (Keymap.KeySpec mods bindable) =
        Keymap.KeySpec (Set.fromList (strip_mods bindable (Set.toList mods)))
            bindable

-- | Strip out redundant modifiers.  E.g. Click and Drag bindings by necessity
-- imply that the mouse button is down, but I don't need to print that out.
strip_mods :: Keymap.Bindable -> [Cmd.Modifier] -> [Cmd.Modifier]
strip_mods bindable mods = case bindable of
    Keymap.Click {} -> stripped
    Keymap.Drag {} -> stripped
    _ -> mods
    where
    stripped = filter (not . is_mouse) mods
    is_mouse (Cmd.MouseMod {}) = True
    is_mouse _ = False

-- * txt fmt

txt_fmt :: Binds -> String
txt_fmt = Seq.join "\n" . map (uncurry show_binding)

show_binding :: String -> [Keymap.KeySpec] -> String
show_binding name keyspecs = Seq.join2 " - " mods name
    where mods = "[" ++ Seq.join ", " (map Pretty.pretty keyspecs) ++ "]"

-- * html fmt

html_fmt :: String -> Binds -> String
html_fmt title binds = columns title 3 (map (uncurry html_binding) binds)

columns :: String -> Int -> [String] -> String
columns title n contents = unlines $
    [ "<table width=100%>"
    , Printf.printf "<tr> <th colspan=%d> %s </th> </tr>" n title
    , "<tr>"
    ] ++ ["<td>" ++ t ++ "</td>" | t <- tables] ++ ["</tr>", "</table>"]
    where
    size = fromIntegral (length contents) / fromIntegral n
    tables = map fmt_table (chunk (ceiling size) contents)
    fmt_table rows = unlines $ ["<table>"] ++ fmt_rows rows ++ ["</table>"]
    fmt_rows rows = [Printf.printf "<tr bgcolor=%s> %s </tr>" color row
        | (color, row) <- zip (cycle ["white", "#dddddd"]) rows]

chunk :: Int -> [a] -> [[a]]
chunk _ [] = []
chunk n xs = c : chunk n rest
    where (c, rest) = splitAt n xs

html_binding :: String -> [Keymap.KeySpec] -> String
html_binding name keyspecs =
    "<td>" ++ mods ++ "</td> <td> <em>" ++ name ++ "</em> </td>"
    where
    mods = Seq.join ", " (map html_keyspec keyspecs)

html_keyspec :: Keymap.KeySpec -> String
html_keyspec (Keymap.KeySpec mods bindable) =
    Seq.join2 " " (show_mods mods)
        ("<b>" ++ Keymap.show_bindable False bindable ++ "</b>")
    where show_mods = Seq.join " + " . map Keymap.show_mod . Set.toList


-- * test

-- test = putStrLn (txt_fmt (extract test_binds))
--
-- test_binds :: CmdMap
-- test_binds = fst $ Keymap.make_cmd_map $ concat
--     [ Keymap.bind_repeatable [Keymap.PrimaryCommand] Key.Down "repeatable"
--         (return ())
--     , Keymap.bind_drag [] 1 "drag" (const (return ()))
--     ]
