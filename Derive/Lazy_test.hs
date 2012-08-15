module Derive.Lazy_test where
import qualified Control.Concurrent.MVar as MVar
import qualified Data.List as List
import qualified System.IO.Unsafe as Unsafe

import Util.Control
import qualified Util.Log as Log
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq
import Util.Test
import qualified Util.Thread as Thread

import qualified Ui.Event as Event
import qualified Ui.State as State
import qualified Ui.UiTest as UiTest

import qualified Derive.Args as Args
import qualified Derive.Call.Block as Call.Block
import qualified Derive.Call.Block as Block
import qualified Derive.Call.BlockUtil as BlockUtil
import qualified Derive.Call.CallTest as CallTest
import qualified Derive.Call.Note as Call.Note
import qualified Derive.CallSig as CallSig
import qualified Derive.Derive as Derive
import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.Deriver.Internal as Internal
import qualified Derive.LEvent as LEvent
import qualified Derive.Note as Note
import qualified Derive.Score as Score
import qualified Derive.Stack as Stack

import qualified Perform.RealTime as RealTime
import qualified Perform.Signal as Signal
import Types


test_one = do
    -- Test laziness of a single track with error logging.
    let mkblock n = snd $ UiTest.run_mkblock
            [(">i", [(fromIntegral n, 1, if n `mod` 4 == 0 then "bad" else "")
                | n <- [0..n]])]
    (log, result) <- derive_block (mkblock 10)
    print $ take 3 $ extract_start result
    evaluated <- get_log log
    equal (length evaluated) 2 -- 1 was an error

test_two = do
    -- Two tracks should interleave evaluation.
    let mkblock n = snd $ UiTest.run_mkblock
            [ (">i1", [(fromIntegral n, 1, "") | n <- [0..n]])
            , (">i2", [(fromIntegral n, 1, "") | n <- [0,2..n]])
            ]
    (log, result) <- derive_block (mkblock 10)
    print $ take 4 $ extract_start result
    evaluated <- get_log log
    -- 4+1 extra because it has to evaluate one in advance to know how to merge
    equal evaluated
        [ "b01 b01.t01 0-1 note at: 0s"
        , "b01 b01.t02 0-1 note at: 0s"
        , "b01 b01.t01 1-2 note at: 1s"
        , "b01 b01.t02 2-3 note at: 2s"
        , "b01 b01.t01 2-3 note at: 2s"
        ]

test_control = do
    -- A control track won't derive in parallel with its note track.  Of
    -- course it would be nice to evaluate the control track incrementally as
    -- well, but not possible as long as signals are strict.  If they were
    -- lazy I'd have to modify a bunch of other places like the bsearches so
    -- I'm not going to bother for now.  It's not even clear it would be more
    -- efficient that way given that signals may be displayed.
    let mkblock n = snd $ UiTest.run_mkblock
            [ ("c", [(fromIntegral n, 0, show n) | n <- [0..n]])
            , (">i", [(fromIntegral n, 1, "") | n <- [0..n]])
            ]
    (log, result) <- derive_block (mkblock 20)
    let extract e = (Score.event_start e, DeriveTest.e_control "c" e)
    print $ take 3 $ DeriveTest.extract_stream extract result
    -- Fails as expected... but can I at least make it go forwards?  Or does
    -- it matter?
    evaluated <- get_log log
    equal (length (filter ("note at" `List.isInfixOf`) evaluated)) 3
    equal (length (filter ("control at" `List.isInfixOf`) evaluated)) 21

test_inverted_control = do
    -- On the other hand, inverted control tracks naturally derive
    -- incrementally.
    let mkblock n = snd $ UiTest.run_mkblock
            [ (">i", [(fromIntegral n, 1, "") | n <- [0..n]])
            , ("c", [(fromIntegral n, 0, show n) | n <- [0..n]])
            ]
    (log, result) <- derive_block (mkblock 20)
    let extract e = (Score.event_start e, DeriveTest.e_control "c" e)
    print $ take 3 $ DeriveTest.extract_stream extract result
    evaluated <- get_log log
    equal (length (filter ("note at" `List.isInfixOf`) evaluated)) 3
    equal (length (filter ("control at" `List.isInfixOf`) evaluated)) 6
    pprint evaluated

test_cache = do
    -- Make sure having some bits cached doesn't mess up lazy derivation.
    let mkblock n = UiTest.exec State.empty $ UiTest.mkblocks
            [ ("top", [(">i", [(fromIntegral n, 1, "sub") | n <- [0..n]])])
            , ("sub", [(">", [(0, 1, "")])])
            ]
    let ustate = mkblock 10
        derive cache damage = do
            (log, deriver) <- with_logging $
                Call.Block.eval_root_block (UiTest.bid "top")
            return (log, DeriveTest.derive_cache cache damage ustate deriver)
    (log, res1) <- derive mempty mempty
    equal (extract_start res1) (map (Left . RealTime.seconds) [0..10])
    evaluated <- get_log log
    equal (length evaluated) 11

    (log, res2) <- derive (Derive.r_cache res1) mempty
    equal (extract_start res2) (extract_start res1)
    evaluated <- get_log log
    -- Everything was cached.
    equal evaluated []

    (log, res2) <- derive (Derive.r_cache res1)
        (DeriveTest.make_damage "top" 1 1 3)
    print $ take 1 $ extract_start res2
    -- Only the first damaged event was rederived.
    evaluated <- get_log log
    equal (length evaluated) 1
    print $ extract_start res2
    evaluated <- get_log log
    -- Both were rederived, and no more.
    equal (length evaluated) 2

test_everything = do
    -- Run a complete derive through performance.
    let ustate = UiTest.exec State.empty $ UiTest.mkblocks
            [ (default_block,
                [ ("*twelve", [(0, 0, "4c")])
                , (">s/1", [(0, 1, ""), (1, 1, "bad"), (2, 1, "sub"),
                    (3, 1, "sub")])
                ])
            , ("sub", [(">", [(0, 1, "")])])
            ]
    (log, res) <- derive_block ustate
    let midi = perform res
    print (take 4 midi)
    -- Make sure errors make it all the way through.
    equal (take 1 [msg | Right msg <- midi])
        ["Error: note call not found: bad"]
    evaluated <- get_log log
    equal evaluated
        ["b01 b01.t02 0-1 note at: 0s", "sub sub.t01 0-1 note at: 2s"]
    where
    perform :: Derive.Result -> [Either DeriveTest.Midi String]
    perform result = map (LEvent.either Left (Right . DeriveTest.show_log)) $
        snd $ DeriveTest.perform_stream DeriveTest.default_convert_lookup
            DeriveTest.default_midi_config (Derive.r_events result)

test_track_signal = do
    -- Ensure that track signals are only derived twice if the TrackSignal is
    -- actually inspected.
    let ustate = snd $ UiTest.run_mkblock
            [ ("tempo", [(0, 0, "1"), (1, 0, ".5")])
            , ("c1", [(0, 0, "0")])
            , (">", [(0, 1, "")])
            ]
    (log, res) <- derive_block ustate
    let t1_derived = length . filter ("b01.t02" `List.isInfixOf`) <$>
            get_log log
    -- force just the events
    print (DeriveTest.extract Score.event_controls res)
    io_equal t1_derived 1
    -- force the track signals as well
    print (Derive.r_track_signals res)
    io_equal t1_derived 2


-- * lazy checks

-- This set of test_#_* test the laziness at various points of the derivation.
-- Since you can only find the too-strict bit of code through manual
-- searching, this should split up the evaluation stack enough to isolate
-- the too-strict section.

test_0_derive_notes = do
    -- if I can take results from an infinite score, the derivation is lazy
    let inf = [UiTest.make_event (n, 1, "") | n <- Seq.range_ 0 1]
    (log, deriver) <- with_logging $
        Note.derive_notes 10 (0, 10) 0 [] ([], []) inf
    result <- Thread.timeout 0.5 $ (\v -> force v >> return v) $
        extract_run 5 $ DeriveTest.run State.empty deriver
    equal result (Just (Right [0, 1, 2, 3, 4]))
    evaluated <- get_log log
    equal (length evaluated) 5

test_1_note_deriver = do
    let ustate = flat_block 20
    -- Since I'm not calling Block.eval_root_block I need to set the stack
    -- manually.
    (log, deriver) <- with_logging $
        Internal.with_stack_block default_block_id $ UiTest.eval ustate $
            BlockUtil.note_deriver default_block_id
    let result = DeriveTest.run_ ustate deriver
    print $ extract_run 5 result
    evaluated <- get_log log
    equal (length evaluated) 5

test_2_root = do
    let ustate = flat_block 20
    (log, deriver) <- with_logging $ Block.eval_root_block default_block_id
    let result = DeriveTest.run_ ustate deriver
    print $ extract_run 5 result
    evaluated <- get_log log
    equal (length evaluated) 5

flat_block :: Int -> State.State
flat_block n = snd $ UiTest.run_mkblock
    [(">i", [(t, 1, "") | t <- Seq.range 0 (fromIntegral n) 1])]

with_logging :: Derive.Deriver a -> IO (Log, Derive.Deriver a)
with_logging deriver = do
    log <- MVar.newMVar []
    return (log, with_calls log deriver)

extract_run :: Int
    -> Either String ([LEvent.LEvent Score.Event], Derive.State, [Log.Msg])
    -> Either String [RealTime]
extract_run n = fmap (take n) . DeriveTest.extract_run
    (map Score.event_start . LEvent.events_of)


-- * implementation

derive_block :: State.State -> IO (Log, Derive.Result)
derive_block ustate = do
    log <- MVar.newMVar []
    return (log,
        DeriveTest.derive_block_with (with_calls log) ustate default_block_id)

default_block = UiTest.default_block_name
default_block_id = UiTest.default_block_id

extract_start :: Derive.Result -> [Either RealTime String]
extract_start = DeriveTest.extract_stream Score.event_start

type Log = MVar.MVar [String]

put_log :: Log -> String -> IO ()
put_log log msg = MVar.modifyMVar_ log (\msgs -> return (msg:msgs))

get_log :: Log -> IO [String]
get_log = fmap reverse . MVar.readMVar

print_log :: Log -> IO ()
print_log log = pslist =<< get_log log

with_calls :: Log -> Derive.Deriver a -> Derive.Deriver a
with_calls mvar = CallTest.with_note_call "" (mk_logging_call mvar)
    . CallTest.with_control_call "" (c_set mvar)

mk_logging_call :: Log -> Derive.NoteCall
mk_logging_call log_var  = Derive.stream_generator "logging-note" $
    Call.Note.inverting $ \args ->
        c_note log_var (Args.event args) (Args.next args)

c_note :: Log -> Event.Event -> ScoreTime -> Derive.EventDeriver
c_note log_mvar event next_start = do
    -- Call the real one to make sure I'm getting it's laziness
    -- characteristics.
    [LEvent.Event sevent] <- Call.Note.generate_note Nothing [] event
        next_start
    st <- Derive.get_stack
    let write_log = Unsafe.unsafePerformIO $ put_log log_mvar $
            stack ++ " note at: " ++ Pretty.pretty (Score.event_start sevent)
        stack = Stack.unparse_ui_frame_ $ last $ Stack.to_ui st
    return $! LEvent.one $! LEvent.Event $! write_log `seq` sevent

c_set :: Log -> Derive.ControlCall
c_set log_mvar = Derive.generator1 "set" $ \args -> CallSig.call1 args
    (CallSig.required "val") $ \val -> do
        pos <- Args.real_start args
        st <- Derive.gets Derive.state_dynamic
        let write_log = Unsafe.unsafePerformIO $ put_log log_mvar $
                stack ++ " control at: " ++ Pretty.pretty pos
            stack = Stack.unparse_ui_frame_ $ last $
                Stack.to_ui (Derive.state_stack st)
        return $! write_log `seq` Signal.signal [(pos, val)]
