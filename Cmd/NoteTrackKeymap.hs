-- | Keymap cmds for a NoteTrack.  These apply regardless of the edit mode.
module Cmd.NoteTrackKeymap where
import qualified Ui.Block as Block
import qualified Ui.State as State
import qualified Cmd.Cmd as Cmd
import qualified Cmd.Edit as Edit
import qualified Cmd.Info as Info
import qualified Cmd.Keymap as Keymap
import Cmd.Keymap (command_char, command_only)
import qualified Cmd.Selection as Selection


make_keymap :: (Cmd.M m) => (Keymap.CmdMap m, [String])
make_keymap = Keymap.make_cmd_map $ concat
    [ command_only 'm' "toggle merged" cmd_toggle_merged
    , command_char '.' "dur * 1.5" (Edit.cmd_modify_dur (*1.5))
    , command_char ',' "dur / 1.5" (Edit.cmd_modify_dur (/1.5))
    ]

cmd_toggle_merged :: (Cmd.M m) => m ()
cmd_toggle_merged = do
    (block_id, tracknum, _, _) <- Selection.get_insert
    pitch <- Cmd.require =<< Info.pitch_of_note block_id tracknum
    btrack <- State.get_block_track block_id tracknum
    if null (Block.track_merged btrack)
        then State.merge_track block_id tracknum (State.track_tracknum pitch)
        else State.unmerge_track block_id tracknum
