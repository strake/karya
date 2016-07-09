-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE LambdaCase, ScopedTypeVariables #-}
-- | Realize an abstract solkattu 'S.Sequence' to concrete instrument-dependent
-- 'Note's.
module Derive.Solkattu.Realize where
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Monoid as Monoid
import qualified Data.Text as Text

import qualified Util.Map
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq

import qualified Derive.Solkattu.Solkattu as S
import Global


data Note stroke =
    Note stroke | Rest | Pattern S.Matras | TimeChange S.TimeChange
    deriving (Show)

instance Pretty.Pretty stroke => Pretty.Pretty (Note stroke) where
    pretty Rest = "__"
    pretty (Note s) = pretty s
    pretty (Pattern matras) = "p" <> showt matras
    pretty (TimeChange change) = pretty change

-- | This maps a 'Pattern' of a certain duration to a realization.  S.Matras
-- should equal length [Note].  This is enforced in the constructor 'patterns'.
newtype Patterns stroke = Patterns (Map.Map S.Matras [Note stroke])
    deriving (Show, Pretty.Pretty, Monoid.Monoid)

patterns :: Pretty.Pretty stroke => [(S.Matras, [Note stroke])]
    -> Either Text (Patterns stroke)
patterns pairs
    | null wrong = Right $ Patterns $ Map.fromList pairs
    | otherwise = Left $ Text.intercalate "; " wrong
    where
    wrong =
        [ "matras should match notes: " <> showt matras <> " /= " <> pretty ns
        | (matras, ns) <- pairs
        , matras /= length ns
        ]

-- | Sollus and Strokes should be the same length.  This is enforced in the
-- constructor 'stroke_map'.  Nothing is a rest, which applies to longer
-- sequences like dinga.
newtype StrokeMap stroke = StrokeMap (Map.Map [S.Sollu] [Maybe stroke])
    deriving (Show, Pretty.Pretty, Monoid.Monoid)

stroke_map :: Pretty.Pretty stroke => [(S.Sequence stroke, [Note stroke])]
    -> Either Text (StrokeMap stroke)
stroke_map = unique <=< mapM verify
    where
    verify (sollus, strokes) = do
        let throw = Left
                . (("stroke map " <> pretty (sollus, strokes) <> ": ") <>)
        sollus <- fmap Maybe.catMaybes $ forM sollus $ \case
            S.Sollu s _ -> Right (Just s)
            S.Rest -> Right Nothing
            s -> throw $ "should only have plain sollus: " <> pretty s
        strokes <- forM strokes $ \case
            Note s -> Right (Just s)
            Rest -> Right Nothing
            s -> throw $ "should have plain strokes: " <> pretty s
        unless (length sollus == length strokes) $
            throw "sollus and strokes have differing lengths after removing\
                \ sollu rests"
        return (sollus, strokes)
    unique pairs
        | null dups = Right (StrokeMap smap)
        | otherwise = Left $ "duplicate StrokeMap keys: " <> pretty dups
        where (smap, dups) = Util.Map.unique2 pairs

-- | Sollu to instrument stroke mapping.
data Instrument stroke = Instrument {
    inst_stroke_map :: StrokeMap stroke
    , inst_patterns :: Patterns stroke
    } deriving (Show)

instance Monoid.Monoid (Instrument stroke) where
    mempty = Instrument mempty mempty
    mappend (Instrument a1 b1) (Instrument a2 b2) = Instrument (a1<>a2) (b1<>b2)

instance Pretty.Pretty stroke => Pretty.Pretty (Instrument stroke) where
    format (Instrument stroke_map patterns) = Pretty.record "Instrument"
        [ ("stroke_map", Pretty.format stroke_map)
        , ("patterns", Pretty.format patterns)
        ]

instrument :: Pretty.Pretty stroke => StrokeMap stroke
    -> [(S.Sequence stroke, [Note stroke])] -> Patterns stroke
    -> Either Text (Instrument stroke)
instrument defaults strokes patterns = do
    smap <- stroke_map strokes
    return $ Instrument
        { inst_stroke_map = smap <> defaults
        , inst_patterns = patterns
        }

-- * realize

realize :: forall stroke. Pretty.Pretty stroke => Bool -> Instrument stroke
    -> [S.Note stroke] -> Either [Text] [Note stroke]
realize realize_patterns (Instrument smap (Patterns patterns)) =
    format_error . go
    where
    go :: [S.Note stroke] -> ([[Note stroke]], Maybe (Text, [S.Note stroke]))
    go [] = ([], Nothing)
    go (n : ns) = case n of
        S.Pattern dur
            | realize_patterns -> case Map.lookup dur patterns of
                Nothing ->
                    ([], Just ("no pattern with duration " <> showt dur, n:ns))
                Just mseq -> first (mseq:) (go ns)
            | otherwise -> first ([Pattern dur] :) (go ns)
        S.Rest -> first ([Rest] :) (go ns)
        S.Sollu sollu stroke ->
            case find_sequence smap sollu stroke ns of
                Right (strokes, rest) -> first (strokes:) (go rest)
                Left err -> ([], Just (err, n:ns))
        S.Alignment {} -> go ns
        S.TimeChange change -> first ([TimeChange change] :) (go ns)
    format_error (result, Nothing) = Right (concat result)
    format_error (pre, Just (err, post)) = Left $
        [ Text.intercalate " / " $ map pretty_strokes pre
        , "*** " <> err
        , Text.unwords (map pretty post)
        ]

pretty_strokes :: Pretty.Pretty stroke => [Note stroke] -> Text
pretty_strokes = Text.unwords . map (Text.justifyLeft 2 ' ' . pretty)

-- | Find the longest matching sequence until the sollus are consumed or
-- a sequence isn't found.
find_sequence :: StrokeMap stroke -> S.Sollu -> Maybe stroke -> [S.Note stroke]
    -> Either Text ([Note stroke], [S.Note stroke])
find_sequence (StrokeMap smap) sollu stroke notes =
    case longest_match (sollu : sollus) of
        Nothing -> Left $ "sequence not found: " <> pretty (sollu : sollus)
        Just strokes ->
            Right $ replace_strokes strokes (S.Sollu sollu stroke : notes)
    where
    -- Collect only sollus and rests, and strip the rests.
    sollus = Maybe.catMaybes $ fst $ Seq.span_while is_sollu notes
    is_sollu (S.Sollu s _) = Just (Just s)
    is_sollu (S.Rest {}) = Just Nothing
    is_sollu _ = Nothing
    longest_match = Seq.head . mapMaybe (flip Map.lookup smap) . reverse
        . drop 1 . List.inits

-- | Match each stroke to its 'Note', and insert rests where the SNotes have
-- one.
replace_strokes :: [Maybe stroke] -> [S.Note stroke]
    -> ([Note stroke], [S.Note stroke])
replace_strokes [] ns = ([], ns)
replace_strokes (stroke : strokes) (n : ns) = case n of
    S.Rest -> first (Rest :) skip
    S.Sollu _ explicit_stroke ->
        first (maybe (maybe Rest Note stroke) Note explicit_stroke :) $
            replace_strokes strokes ns
    -- These shouldn't happen because the strokes are from the result of
    -- Seq.span_while is_sollu.
    S.Pattern {} -> skip
    S.Alignment {} -> skip
    S.TimeChange {} -> skip
    where
    skip = replace_strokes (stroke : strokes) ns
replace_strokes (_:_) [] = ([], [])
    -- This shouldn't happen because strokes from the StrokeMap should be
    -- the same length as the RealizedNotes used to find them.


-- * format

-- | Format the notes according to the tala.
format :: forall stroke. Pretty.Pretty stroke => S.Tala -> [Note stroke] -> Text
format tala = Text.stripStart . mconcat
    . S.map_time tala per_word . S.map_time tala per_note
    where
    per_note _ note = case note of
        Rest -> (Right 1, [Right "_"])
        Note n -> (Right 1, [Right (pretty n)])
        Pattern matras ->
            ( Right (fromIntegral matras)
            , map Right $ pretty (Pattern matras :: Note stroke)
                : replicate (matras - 1) "--"
            )
        TimeChange change -> (Left change, [Left change])
    per_word _ (Left change) = (Left change, [])
    per_word state (Right word) =
        (Right 1, [newline <> add_emphasis (pad word)])
        where
        -- TODO look for the highest speed, and normalize to that
        pad = Text.justifyLeft
            (if S.state_speed state == S.S1 then 2 else 0) ' '
        add_emphasis s
            | not (Text.null s) && matra == 0 = emphasize s
            | otherwise = s
        newline
            | matra == 0 && S.state_akshara state == 0 = "\n\n"
            | matra == 0 && S.state_akshara state == S.tala_arudi tala = "\n"
            | otherwise = ""
        matra = S.state_matra state
    emphasize txt = "\ESC[1m" <> txt <> "\ESC[0m"