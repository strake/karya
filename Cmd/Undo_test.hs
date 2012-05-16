module Cmd.Undo_test where
import qualified Data.Map as Map

import Util.Control
import qualified Util.File as File
import qualified Util.Git.Git as Git
import qualified Util.Rect as Rect
import qualified Util.Seq as Seq
import Util.Test

import qualified Ui.Block as Block
import qualified Ui.Event as Event
import qualified Ui.Id as Id
import qualified Ui.State as State
import qualified Ui.Types as Types
import qualified Ui.UiTest as UiTest
import qualified Ui.Update as Update

import qualified Cmd.Cmd as Cmd
import qualified Cmd.CmdTest as CmdTest
import qualified Cmd.Edit as Edit
import qualified Cmd.ResponderTest as ResponderTest
import qualified Cmd.Save as Save
import qualified Cmd.SaveGit as SaveGit
import qualified Cmd.Selection as Selection
import qualified Cmd.Undo as Undo

import qualified App.Config as Config
import Types


test_undo = do
    let states = ResponderTest.mkstates [(">", [(0, 1, "1"), (1, 1, "2")])]

    res <- ResponderTest.respond_cmd states $ Cmd.name "+z" $ insert_event 0 "z"
    res <- next res $ Cmd.name "+q" $ insert_event 1 "q"

    equal (extract_ui res) "zq"
    equal (e_updates res) [track_update 1 1 2]

    res <- next res Undo.undo
    -- Make sure the past and future have the expected names and states.
    equal (extract_hist res) (["+z: z2", "setup: 12"], ["+q: zq"])
    equal (extract_ui res) "z2"
    equal (e_updates res) [track_update 1 1 2]

    res <- next res Undo.undo
    equal (extract_hist res) (["setup: 12"], ["+z: z2", "+q: zq"])
    equal (extract_ui res) "12"
    equal (e_updates res) [track_update 1 0 1]

    -- no past to undo
    res <- next res Undo.undo
    equal (extract_ui res) "12"
    equal (e_updates res) []

    res <- next res Undo.redo
    equal (extract_hist res) (["+z: z2", "setup: 12"], ["+q: zq"])
    equal (extract_ui res) "z2"
    equal (e_updates res) [track_update 1 0 1]

    res <- next res Undo.redo
    equal (extract_ui res) "zq"
    equal (extract_hist res) (["+q: zq", "+z: z2", "setup: 12"], [])
    equal (e_updates res) [track_update 1 1 2]

    -- no future to redo
    res <- next res Undo.redo
    equal (extract_ui res) "zq"
    equal (e_updates res) []

test_suppress_history = do
    let states = ResponderTest.mkstates [(">", [(0, 1, "1"), (1, 1, "2")])]
    let suppress = Cmd.suppress_history Cmd.RawEdit

    res <- ResponderTest.respond_cmd states $
        Cmd.name "toggle" Edit.cmd_toggle_raw_edit
    res <- next res $ suppress "+z" $ insert_event 0 "z"
    equal (extract_hist res) (["setup: 12"], [])
    res <- next res $ suppress "+q" $ insert_event 1 "q"
    equal (extract_hist res) (["setup: 12"], [])
    -- A non-recording cmd will cause the suppressed cmds to be recorded.
    res <- next res $ set_sel 1
    res <- next res $ Cmd.name "toggle" Edit.cmd_toggle_raw_edit
    equal (extract_hist res) (["+z: zq", "setup: 12"], [])

test_undo_merge = do
    let states = ResponderTest.mkstates [(">", [])]
        vid = UiTest.default_view_id
    res1 <- ResponderTest.respond_cmd states $ do
        State.set_namespace (Id.unsafe_namespace "oogabooga")
        State.set_view_rect vid $ Rect.xywh 40 40 100 100
        insert_event 0 "z"
    res2 <- ResponderTest.respond_cmd (ResponderTest.result_states res1)
        Undo.undo

    -- pprint (e_hist_updates res1)

    -- some things aren't affected by undo
    -- namespace doesn't change
    let ns = State.config_namespace . State.state_config . e_ui
    equal (ns res1) (Id.unsafe_namespace "oogabooga")
    equal (UiTest.eval (e_ui res1) (Block.view_rect <$> State.get_view vid))
        (Rect.xywh 40 40 100 100)

    equal (ns res2) (Id.unsafe_namespace "oogabooga")
    equal (UiTest.eval (e_ui res2) (Block.view_rect <$> State.get_view vid))
        (Rect.xywh 40 40 100 100)

track_update :: TrackNum -> ScoreTime -> ScoreTime -> Update.DisplayUpdate
track_update tracknum from to = Update.TrackUpdate (UiTest.mk_tid tracknum)
    (Update.TrackEvents from to)

test_load_previous_history = do
    -- Load a git repo and make sure its history comes with it.
    res <- save_git $ ResponderTest.mkstates [(">", [(0, 1, "1")])]
    res <- next res $ Cmd.name "+x" $ insert_event 0 "x"
    res <- next res $ Cmd.name "+y" $ insert_event 1 "y"
    pprint (e_commits res)
    pprint (e_hist_updates res)

    res <- ResponderTest.respond_cmd (ResponderTest.mkstates []) $
        Save.cmd_load_git "build/test/test.git" Nothing
    equal (extract_ui res) "xy"

    res <- next res Undo.undo
    -- Previous history was loaded, y deleted.
    equal (extract_hist res) (["+x: x"], ["+y: xy"])
    equal (extract_ui res) "x"
    equal (e_updates res) [track_update 1 1 2]

    res <- next res Undo.undo
    -- Previous history was loaded, x replaced with 1.
    equal (extract_hist res) (["save: 1"], ["+x: x", "+y: xy"])
    equal (extract_ui res) "1"
    equal (e_updates res) [track_update 1 0 1]

    -- out of past
    res <- next res Undo.undo
    equal (extract_ui res) "1"
    equal (e_updates res) []

    res <- next res Undo.redo
    equal (extract_ui res) "x"
    equal (e_updates res) [track_update 1 0 1]
    res <- next res Undo.redo
    equal (extract_ui res) "xy"
    equal (e_updates res) [track_update 1 1 2]

test_load_next_history = do
    res <- save_git $ ResponderTest.mkstates [(">", [(0, 1, "1")])]
    res <- next res $ Cmd.name "+x" $ insert_event 0 "x"
    res <- next res $ Cmd.name "+y" $ insert_event 1 "y"
    pprint (e_commits res)
    -- The creation state wasn't committed, and the save isn't recorded in the
    -- history even though it has a commit, so start at the second-to-last.
    let ([_, ent, _], _) = e_commits res
        (_, Just commit) = ent
    res <- ResponderTest.respond_cmd (ResponderTest.mkstates []) $
        Save.cmd_load_git "build/test/test.git" (Just commit)
    equal (extract_hist res) (["+x: x"], [])
    equal (extract_ui res) "x"

    res <- next res Undo.redo
    equal (extract_ui res) "xy"
    equal (extract_hist res) (["+y: xy", "+x: x"], [])
    equal (e_updates res) [track_update 1 1 2]

    -- No future to redo.
    res <- next res Undo.redo
    equal (extract_ui res) "xy"
    equal (e_updates res) []

    -- Make sure I can do back again.
    res <- next res Undo.undo
    equal (extract_ui res) "x"
    equal (e_updates res) [track_update 1 1 2]

    res <- next res Undo.undo
    equal (extract_ui res) "1"
    equal (e_updates res) [track_update 1 0 1]

test_branching_history = do
    res <- save_git $ ResponderTest.mkstates [(">", [(0, 1, "1")])]
    res <- next res $ Cmd.name "+x" $ insert_event 0 "x"
    res <- next res $ Cmd.name "+y" $ insert_event 1 "y"
    res <- next res $ Cmd.name "save" Save.cmd_save_git
    res <- next res $ Cmd.name "revert" $ Save.cmd_revert (Just "0")
    equal (extract_ui res) "1"
    res <- next res $ Cmd.name "+a" $ insert_event 0 "a"
    res <- next res $ Cmd.name "+b" $ insert_event 1 "b"
    res <- next res $ Cmd.name "save" Save.cmd_save_git

    -- The second branch got 0.0 because 1 was taken.
    refs <- Git.read_refs repo
    equal (Map.keys refs) ["tags/0", "tags/0.0", "tags/1"]

    -- Each branch has its own history.
    io_equal (read_log =<< Git.read_log repo "tags/0.0")
        ["save", "+b", "+a", "save"]
    -- HEAD is at 0.0
    io_equal (read_log =<< Git.read_log_head repo)
        ["save", "+b", "+a", "save"]
    io_equal (read_log =<< Git.read_log repo "tags/1")
        ["save", "+y", "+x", "save"]

    equal (extract_ui res) "ab"
    res <- next res $ Cmd.name "revert" $ Save.cmd_revert (Just "1")
    equal (extract_ui res) "xy"

read_log :: [Git.Commit] -> IO [String]
read_log commits = do
    texts <- mapM (fmap Git.commit_text . Git.read_commit repo) commits
    mapM (fmap head . SaveGit.parse_names) texts

save_git :: ResponderTest.States -> IO ResponderTest.Result
save_git states = do
    File.recursive_rm_dir repo
    ResponderTest.respond_cmd (first set_dir states) Save.cmd_save_git
    where
    set_dir = (State.config#State.project_dir #= "build/test")
        . (State.config#State.namespace #= Id.unsafe_namespace "test")

repo :: Git.Repo
repo = "build/test/test.git"

-- * implementation

insert_event :: (State.M m) => ScoreTime -> String -> m ()
insert_event pos text =
    State.insert_event (UiTest.mk_tid 1) pos (Event.event text 1)

set_sel :: (Cmd.M m) => ScoreTime -> m ()
set_sel pos = Cmd.name "select" $ Selection.set_current Config.insert_selnum
    (Just (Types.point_selection 1 pos))

next :: ResponderTest.Result -> Cmd.CmdT IO a -> IO ResponderTest.Result
next = ResponderTest.respond_cmd . ResponderTest.result_states


-- ** extract

extract_hist :: ResponderTest.Result -> ([String], [String])
extract_hist res = (map extract past, map extract future)
    where
    Cmd.History past future _ = e_hist res
    -- Cmd.HistoryCollect _updates _cmd_names _suppress _suppressed =
    --     e_hist_collect res
    extract (Cmd.HistoryEntry state _ names _) =
        Seq.join "+" names ++ ": " ++ ui_notes 0 state

e_commits :: ResponderTest.Result
    -> ([([String], Maybe Git.Commit)], [([String], Maybe Git.Commit)])
e_commits res = (map extract past, map extract future)
    where
    Cmd.History past future _ = e_hist res
    extract hist = (Cmd.hist_names hist, Cmd.hist_commit hist)

extract_ui :: ResponderTest.Result -> String
extract_ui = ui_notes 0 . e_ui

ui_notes :: Int -> State.State -> String
ui_notes tracknum ui_state = [c | (_, _, c:_) <- tracks]
    where ('>' : _, tracks) = UiTest.extract_tracks ui_state !! tracknum

e_ui :: ResponderTest.Result -> State.State
e_ui = CmdTest.result_ui_state . ResponderTest.result_cmd

e_hist_updates :: ResponderTest.Result
    -> ([[Update.CmdUpdate]], [[Update.CmdUpdate]])
e_hist_updates = hist_updates . e_hist

e_hist :: ResponderTest.Result -> Cmd.History
e_hist = Cmd.state_history . CmdTest.result_cmd_state . ResponderTest.result_cmd

e_hist_collect :: ResponderTest.Result -> Cmd.HistoryCollect
e_hist_collect = Cmd.state_history_collect . CmdTest.result_cmd_state
    . ResponderTest.result_cmd

hist_updates :: Cmd.History -> ([[Update.CmdUpdate]], [[Update.CmdUpdate]])
hist_updates (Cmd.History past future _undo_redo) =
    (map Cmd.hist_updates past, map Cmd.hist_updates future)

e_updates :: ResponderTest.Result -> [Update.DisplayUpdate]
e_updates = ResponderTest.result_updates
