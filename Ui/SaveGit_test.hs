module Ui.SaveGit_test where
import qualified System.Directory as Directory

import Util.Control
import qualified Util.File as File
import qualified Util.Git as Git
import Util.Test

import qualified Ui.Diff as Diff
import qualified Ui.Event as Event
import qualified Ui.Id as Id
import qualified Ui.SaveGit as SaveGit
import qualified Ui.State as State
import qualified Ui.Track as Track
import qualified Ui.UiTest as UiTest
import qualified Ui.Update as Update


test_save = do
    repo <- new_repo
    let state = snd $ UiTest.run_mkview
            [ ("1", [(0, 1, "1a"), (1, 1, "1b")])
            , ("2", [(0, 1, "2a")])
            ]
    SaveGit.save repo state
    Right state2 <- SaveGit.load repo Nothing
    equal state state2
    let state3 = UiTest.exec state2 $ do
            State.destroy_view UiTest.default_view_id
            State.insert_event (UiTest.mk_tid 1) 2 (Event.event "hi" 2)
    SaveGit.save repo state3

test_checkpoint = do
    let tracks =
            [ ("1", [(0, 1, "1a"), (1, 1, "1b")])
            , ("2", [(0, 1, "2a")])
            ]
    repo <- new_repo
    [(state1, commit1), (state2, commit2), (state3, commit3),
            (state4, commit4)] <- checkpoint_sequence repo
        [ void $ UiTest.mkblock_view (UiTest.default_block_name, tracks)
        , State.insert_event (UiTest.mk_tid 1) 2 (Event.event "hi" 2)
        , do
            State.destroy_track (UiTest.mk_tid 2)
            void $ State.create_track (Id.unpack_id (UiTest.mk_tid 2)) $
                Track.track "new" []
        , do
            State.destroy_view UiTest.default_view_id
            State.destroy_block UiTest.default_block_id
        ]
    -- TODO hook up a fs simulator so I can test this exhaustively without
    -- hitting git

    io_equal (SaveGit.load repo Nothing) (Right state4)
    -- Previous states load correctly.
    io_equal (SaveGit.load repo (Just commit1)) (Right state1)
    io_equal (SaveGit.load repo (Just commit2)) (Right state2)
    io_equal (SaveGit.load repo (Just commit3)) (Right state3)
    io_equal (SaveGit.load repo (Just commit4)) (Right state4)

    -- Make sure incremental loads work.
    io_equal (SaveGit.load_from repo commit1 (Just commit2) state1)
        (Right state2)
    io_equal (SaveGit.load_from repo commit2 (Just commit3) state2)
        (Right state3)
    io_equal (SaveGit.load_from repo commit3 (Just commit4) state3)
        (Right state4)
    io_equal (SaveGit.load_from repo commit1 (Just commit4) state1)
        (Right state4)

test_sequence = do
    let tracks =
            [ ("1", [(0, 1, "1a"), (1, 1, "1b")])
            , ("2", [(0, 1, "2a")])
            ]
    repo <- new_repo
    states <- checkpoint_sequence repo []
    mapM_ (check_load repo) states
    mapM_ (uncurry (check_load_from repo)) (zip states (drop 1 states))

check_load repo (state, commit) =
    io_equal (SaveGit.load repo (Just commit)) (Right state)

check_load_from repo (state1, commit1) (state2, commit2) =
    io_equal (SaveGit.load_from repo commit1 (Just commit2) state1)
        (Right state2)

-- (state, commit)

checkpoint_sequence :: Git.Repo -> [State.StateId ()]
    -> IO [(State.State, Git.Commit)]
checkpoint_sequence repo actions = apply State.empty actions
    where
    apply _ [] = return []
    apply prev_state (action : actions) = do
        let (state, updates) = diff prev_state action
        Right commit <- SaveGit.checkpoint repo state updates
        rest <- apply state actions
        return $ (state, commit) : rest

diff :: State.State -> State.StateId a -> (State.State, [Update.CmdUpdate])
diff state modify = case Diff.diff cmd_updates state state2 of
        Left err -> error $ "diff: " ++ show err
        Right (updates, _) -> (state2, updates)
    where
    (state2, cmd_updates) = case State.run_id state modify of
        Left err -> error $ "State.run: " ++ show err
        Right (_, state, updates) -> (state, updates)


new_repo = do
    let repo = "build/test/test-repo"
    File.ignore_enoent $ Directory.removeDirectoryRecursive repo
    return repo
