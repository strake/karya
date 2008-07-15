module Ui.Track_test where
import qualified Data.Map as Map

import Util.Test

import Ui.Types
import qualified Ui.Event as Event
import qualified Ui.Track as Track
import qualified Ui.TestSetup as TestSetup

-- TODO improve tests

track_events = Track.make_track_events . events

test_events_at_before = do
    let e1 = track_events [(0, "0", 1), (1, "1", 1), (2, "2", 1)]
    let f pos = let (pre, post) = Track.events_at_before pos e1
            in (map extract_text pre, map extract_text post)
    equal (f 0) ([], ["0", "1", "2"])
    equal (f 0.5) ([], ["0", "1", "2"])
    equal (f 1) (["0"], ["1", "2"])
    equal (f 1.5) (["0"], ["1", "2"])

extract_text :: Track.PosEvent -> String
extract_text (_, event) = Event.event_text event


-- * cruft

test_merge0 = do
    -- 0 dur events
    let te1 = merge Track.empty_events [(0, "0", 0), (16, "16", 0)]
    equal (extract te1) [(0, "0", 0), (16, "16", 0)]
    no_overlaps te1

    let te2 = merge te1 [(0, "0b", 0), (16, "16b", 0)]
    print (extract te2)
    equal (extract te2) [(0, "0b", 0), (16, "16b", 0)]
    print (merge_info te1 te2)

{-
em1 = Track.un_event_map (merge Track.empty_events [(0, "0", 0), (16, "16", 0)])
em2 = Track.un_event_map
    (merge (Track.TrackEvents em1) [(0, "0b", 0), (16, "16b", 0)])

tm = Map.fromList [(1, 'a'), (2, 'b'), (3, 'c'), (4, 'd'), (5, 'e')]
t1 = Track.merge_range 2 3 tm
-}

test_merge = do
    let te1 = merge Track.empty_events [(0, "0", 8), (16, "16", 8)]
    let te2 = merge te1 [(4, "0", 8), (20, "16", 8)]
    no_overlaps te2
    print (extract te2)
    print (merge_info te1 te2)

test_remove_events = do
    let te1 = merge Track.empty_events [(0, "0", 0), (16, "16", 0)]
    -- remove 0 dur events
    equal (extract $ Track.remove_events (TrackPos 0) (TrackPos 0) te1)
        [(16, "16", 0)]
    equal (extract $ Track.remove_events (TrackPos 16) (TrackPos 16) te1)
        [(0, "0", 0)]
    -- doesn't include end of range
    equal (extract $ Track.remove_events (TrackPos 0) (TrackPos 16) te1)
        [(16, "16", 0)]
    -- get it all
    equal (extract $ Track.remove_events (TrackPos 0) (TrackPos 17) te1)
        []
    -- missed entirely
    equal (extract $ Track.remove_events (TrackPos 4) (TrackPos 10) te1)
        [(0, "0", 0), (16, "16", 0)]

no_overlaps = check . not . events_overlap
events_overlap track = any (uncurry overlaps)
    (zip (Track.event_list track) (drop 1 (Track.event_list track)))

overlaps evt1 evt2 =
    -- They don't overlap and they aren't simultaneous (the second condition is
    -- needed for zero duration events).
    Track.event_end evt1 > fst evt2 || fst evt1 >= fst evt2

merge old_events evts = Track.insert_events (events evts) old_events

merge_info (Track.TrackEvents evts1) (Track.TrackEvents evts2) =
    ( (first_pos, last_pos)
    , (extractm (relevant evts1), extractm (relevant evts2))
    )
    where
    first_pos = max (fst (Map.findMin evts1)) (fst (Map.findMin evts2))
    last_pos = min (Track.event_end (Map.findMax evts2))
        (Track.event_end (Map.findMax evts2))
    relevant = Track.merge_range first_pos last_pos

extract (Track.TrackEvents fm) = extractm fm
extractm event_map = [(pos, Event.event_text evt, dur)
    | (TrackPos pos, evt@(Event.Event { Event.event_duration = TrackPos dur }))
        <- Map.toAscList event_map]


events =
    map (\(pos, text, dur) -> (TrackPos pos, TestSetup.event text dur))
