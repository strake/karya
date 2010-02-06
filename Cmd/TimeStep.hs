{- | A TimeStep is an abstract description of a ScoreTime interval.

    It's used to advance a cursor, snap a selection, set a note duration, etc.
-}
module Cmd.TimeStep where
import Data.Function
import qualified Data.Maybe as Maybe

import qualified Util.Seq as Seq

import Ui
import qualified Ui.Block as Block
import qualified Ui.Ruler as Ruler
import qualified Ui.State as State


-- | A variable time step, used to find out how much to advance
-- the cursor, how long an event should be, etc.
data TimeStep
     -- | Absolute time step.
    = Absolute ScoreTime
    -- | Until the next mark that matches.
    | UntilMark MarklistMatch MarkMatch
    -- | Until next matching mark + offset from previous mark.
    | MarkDistance MarklistMatch MarkMatch
    deriving (Show, Read)

data MarklistMatch = AllMarklists | NamedMarklists [Ruler.MarklistName]
    deriving (Show, Read)

-- | Take a rank and a number of that rank to skip: MatchRank rank skips
data MarkMatch = MatchRank Int Int deriving (Show, Read)
-- | Given a marklist view, return the ScoreTime to advance to.
type Matcher = [(ScoreTime, Ruler.Mark)] -> Maybe ScoreTime

data Direction = Advance | Rewind deriving (Eq, Show)


-- | Given a pos, return the nearest point on a timestep.
snap :: (State.UiStateMonad m) =>
    TimeStep -> BlockId -> TrackNum -> ScoreTime -> m ScoreTime
    -- Absolute steps don't have any absolute alignment, so you can't snap.
snap (Absolute _) _ _ pos = return pos
snap time_step block_id tracknum pos = fmap (Maybe.fromMaybe pos) $
    step_from time_step Rewind block_id tracknum pos

-- | Step in the given direction from the given position, or Nothing if
-- the step is out of range.
step_from :: (State.UiStateMonad m) => TimeStep -> Direction
    -> BlockId -> TrackNum -> ScoreTime -> m (Maybe ScoreTime)
step_from time_step direction block_id tracknum pos = do
    block <- State.get_block block_id
    case relevant_ruler block tracknum of
        Nothing -> return Nothing
        Just ruler_id -> do
            ruler <- State.get_ruler ruler_id
            return $ step direction time_step (Ruler.ruler_marklists ruler) pos
    where
    step Advance = advance
    step Rewind = rewind

-- | Step @n@ times, or until no further stepping is possible.
step_n :: (State.UiStateMonad m) => Int -> TimeStep
    -> BlockId -> TrackNum -> ScoreTime -> m ScoreTime
step_n nsteps time_step block_id tracknum pos = do
    block <- State.get_block block_id
    case relevant_ruler block tracknum of
        Nothing -> return pos
        Just ruler_id -> do
            ruler <- State.get_ruler ruler_id
            return $ step_until (abs nsteps)
                (step time_step (Ruler.ruler_marklists ruler)) pos
    where
    step = if nsteps >= 0 then advance else rewind

step_until :: Int -> (ScoreTime -> Maybe ScoreTime) -> ScoreTime -> ScoreTime
step_until n f x
    | n <= 0 = x
    | otherwise = maybe x (step_until (n-1) f) (f x)

-- | Get the ruler that applies to the given track.  Search left for the
-- closest ruler that has all the given marklist names.  This includes ruler
-- tracks and the rulers of event tracks.
relevant_ruler :: Block.Block -> TrackNum -> Maybe RulerId
relevant_ruler block tracknum = Seq.at (Block.ruler_ids_of in_order) 0
    where
    in_order = map snd $ dropWhile ((/=tracknum) . fst) $ reverse $
        zip [0..] (Block.block_tracklike_ids block)

-- | Advance the given pos according to step on the ruler.
advance :: TimeStep -> [(Ruler.MarklistName, Ruler.Marklist)] -> ScoreTime
    -> Maybe ScoreTime
advance step marklists start_pos = case step of
    Absolute pos -> Just (start_pos + pos)
    UntilMark names matcher -> match matcher
        (relevant_marks marklists names Advance start_pos)
    MarkDistance names matcher -> do
        prev_pos <- match matcher
            (relevant_marks marklists names Rewind start_pos)
        next_pos <- match matcher
            (relevant_marks marklists names Advance start_pos)
        return (next_pos + (start_pos - prev_pos))

-- | Just like 'advance', but get a previous pos.
rewind :: TimeStep -> [(Ruler.MarklistName, Ruler.Marklist)] -> ScoreTime
    -> Maybe ScoreTime
rewind step marklists start_pos = case step of
    Absolute pos -> Just (start_pos - pos)
    UntilMark names matcher -> match matcher
        (relevant_marks marklists names Rewind start_pos)
    MarkDistance names matcher -> do
        prev_pos <- match matcher
            (relevant_marks marklists names Advance start_pos)
        prev_prev_pos <- match matcher
            (relevant_marks marklists names Rewind prev_pos)
        return (prev_prev_pos + (start_pos - prev_pos))

-- Extract @names@ from alist @marklists@, use @to_marks@ to extract marks
-- from @start_pos@, and return the merged result.
relevant_marks marklists names direction start_pos =
    let mlists = case names of
            AllMarklists -> map snd marklists
            NamedMarklists names -> Seq.map_maybe (flip lookup marklists) names
        (cmp, marks) = case direction of
            Advance -> (compare,
                map (flip Ruler.forward_from start_pos) mlists)
            Rewind -> (Seq.reverse_compare,
                map (flip Ruler.backward start_pos) mlists)
    -- Sort on ScoreTime.  foldr is important to preserve laziness.
    in foldr (Seq.merge_by (cmp `on` fst)) [] marks


match :: MarkMatch -> Matcher
match (MatchRank rank skips) = match_rank rank skips

-- | Get the pos of the next mark <= the given rank.
match_rank :: Int -> Int -> Matcher
match_rank rank skips marks = case drop skips matches of
    [] -> Nothing
    (pos, _) : _ -> Just pos
    where matches = filter ((<=rank) . Ruler.mark_rank . snd) marks
