-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE ExistentialQuantification #-}
-- | Tie together generic Solkattu and specific instruments into a single
-- 'Korvai'.
module Solkattu.Korvai where
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as Text.IO
import qualified Data.Time.Calendar as Calendar

import qualified Util.CallStack as CallStack
import qualified Util.Map
import qualified Util.Num as Num
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq
import qualified Util.TextUtil as TextUtil

import qualified Derive.Expr as Expr
import qualified Solkattu.Instrument.KendangTunggal as KendangTunggal
import qualified Solkattu.Instrument.Konnakol as Konnakol
import qualified Solkattu.Instrument.Mridangam as Mridangam
import qualified Solkattu.Instrument.Reyong as Reyong
import qualified Solkattu.Instrument.Sargam as Sargam
import qualified Solkattu.Instrument.ToScore as ToScore
import qualified Solkattu.Realize as Realize
import qualified Solkattu.Sequence as S
import qualified Solkattu.Solkattu as Solkattu
import qualified Solkattu.Tala as Tala

import Global


type Sequence = SequenceT Solkattu.Sollu
type SequenceT sollu = [S.Note Solkattu.Group (Solkattu.Note sollu)]

type Error = Text

mapSollu :: (a -> b) -> SequenceT a -> SequenceT b
mapSollu f = map $ \n -> case n of
    S.Note note -> S.Note (f <$> note)
    S.TempoChange change notes -> S.TempoChange change (mapSollu f notes)
    S.Group g notes -> S.Group g (mapSollu f notes)

-- * korvai

data Korvai = Korvai {
    korvaiSections :: !KorvaiType
    , korvaiStrokeMaps :: !StrokeMaps
    , korvaiTala :: !Tala.Tala
    -- | Expect the korvai to end on sam + eddupu.
    , korvaiEddupu :: !S.Duration
    , korvaiMetadata :: !Metadata
    } deriving (Eq, Show)

data KorvaiType =
    Sollu [Section Solkattu.Sollu]
    | Mridangam [Section (Realize.Stroke Mridangam.Stroke)]
    deriving (Show, Eq)

solluSequence (Sollu seq) = Just seq
solluSequence _ = Nothing

instance Pretty KorvaiType where
    pretty (Sollu a) = pretty a
    pretty (Mridangam a) = pretty a

instance Pretty Korvai where
    format (Korvai sequence strokeMaps tala eddupu metadata) =
        Pretty.record "Korvai"
        [ ("sequence", Pretty.format sequence)
        , ("strokeMaps", Pretty.format strokeMaps)
        , ("tala", Pretty.format tala)
        , ("eddupu", Pretty.format eddupu)
        , ("metadata", Pretty.format metadata)
        ]

korvai :: Tala.Tala -> StrokeMaps -> [Sequence] -> Korvai
korvai tala strokeMaps sequences = Korvai
    { korvaiSections = Sollu $ inferSections sequences
    , korvaiStrokeMaps = strokeMaps
    , korvaiTala = tala
    , korvaiEddupu = 0
    , korvaiMetadata = mempty
    }

mridangamKorvai :: Tala.Tala -> Realize.Patterns Mridangam.Stroke
    -> [SequenceT (Realize.Stroke Mridangam.Stroke)]
    -> Korvai
mridangamKorvai tala pmap sequences = Korvai
    { korvaiSections = Mridangam $ inferSections sequences
    , korvaiStrokeMaps = mempty
        { instMridangam = Realize.Instrument
            { instStrokeMap = mempty
            , instPatterns = pmap
            }
        }
    , korvaiTala = tala
    , korvaiEddupu = 0
    , korvaiMetadata = mempty
    }

eddupu :: S.Duration -> Korvai -> Korvai
eddupu dur korvai = korvai { korvaiEddupu = dur }

withKorvaiMetadata :: Metadata -> Korvai -> Korvai
withKorvaiMetadata meta korvai =
    korvai { korvaiMetadata = meta <> korvaiMetadata korvai }

-- * Section

data Section stroke = Section {
    -- TODO rename this sectionSequence?
    -- I think I like the score terminology better, but sequence is already
    -- used everywhere so I have to change it all at once.  But score is
    -- already used by e.g. ToScore.
    sectionSequence :: !(SequenceT stroke)
    -- | Where the section should start and end.  (0, 0) means start and end on
    -- sam.
    , sectionStart :: !S.Duration
    , sectionEnd :: !S.Duration
    -- | This is lazy because it might have a 'Solkattu.Exception' in it.  This
    -- is because 'inferSectionTags' has to evaluate the sequence.
    , sectionTags :: Tags
    } deriving (Eq, Show)

instance Pretty stroke => Pretty (Section stroke) where
    format (Section seq start end tags) = Pretty.record "Section"
        [ ("tags", Pretty.format tags)
        , ("start", Pretty.format start)
        , ("end", Pretty.format end)
        , ("sequence", Pretty.format seq)
        ]

withSectionTags :: Tags -> Section stroke -> Section stroke
withSectionTags tags section =
    section { sectionTags = tags <> sectionTags section }

section :: SequenceT stroke -> Section stroke
section seq = Section
    { sectionSequence = seq
    , sectionStart = 0
    , sectionEnd = 0
    , sectionTags = mempty
    }

inferSections :: [SequenceT stroke] -> [Section stroke]
inferSections seqs = case Seq.viewr (map section seqs) of
    Just (inits, last) ->
        map (withSectionTags (tag "type" "development")) inits
        ++ [withSectionTags (tag "type" "korvai") last]
    Nothing -> []

-- section tags: type=development, type=korvai
-- local-variation
-- comment

-- * Instrument

-- | Tie together everything describing how to realize a single instrument.
data Instrument stroke = Instrument {
    instFromSollu :: Realize.StrokeMap stroke
        -> Realize.GetStroke Solkattu.Sollu stroke
    , instFromMridangam ::
        Maybe (Realize.GetStroke (Realize.Stroke Mridangam.Stroke) stroke)
    , instFromStrokes :: StrokeMaps -> Realize.Instrument stroke
    -- | Modify strokes after 'realize'.  Use with 'strokeTechnique'.
    , instPostprocess :: [Flat stroke] -> [Flat stroke]
    , instToScore :: ToScore.ToScore stroke
    }

defaultInstrument :: Expr.ToExpr (Realize.Stroke stroke) => Instrument stroke
defaultInstrument = Instrument
    { instFromSollu = Realize.realizeSollu
    , instFromMridangam = Nothing
    , instFromStrokes = const mempty
    , instPostprocess = id
    , instToScore = ToScore.toScore
    }

mridangam :: Instrument Mridangam.Stroke
mridangam = defaultInstrument
    { instFromMridangam = Just Realize.realizeStroke
    , instPostprocess = Mridangam.postprocess
    , instFromStrokes = instMridangam
    }

konnakol :: Instrument Solkattu.Sollu
konnakol = defaultInstrument
    { instFromSollu = const Realize.realizeSimpleStroke
    , instFromStrokes = const $ Realize.Instrument
        { instStrokeMap = mempty
        -- TODO to control the patterns, I could modify
        -- konnakol.getRealization
        , instPatterns = Konnakol.defaultPatterns
        }
    }

kendangTunggal :: Instrument KendangTunggal.Stroke
kendangTunggal = defaultInstrument { instFromStrokes = instKendangTunggal }

reyong :: Instrument Reyong.Stroke
reyong = defaultInstrument { instFromStrokes = instReyong }

sargam :: Instrument Sargam.Stroke
sargam = defaultInstrument
    { instFromStrokes = instSargam
    , instToScore = Sargam.toScore
    }

-- | An existential type to capture the Notation instance.
data GInstrument =
    forall stroke. Solkattu.Notation stroke => GInstrument (Instrument stroke)

instruments :: Map Text GInstrument
instruments = Map.fromList
    [ ("mridangam", GInstrument mridangam)
    , ("konnakol", GInstrument konnakol)
    , ("kendang tunggal", GInstrument kendangTunggal)
    , ("reyong", GInstrument reyong)
    , ("sargam", GInstrument sargam)
    ]

-- * realize

-- | Fully realized notes.
type Flat stroke =
    S.Flat (Realize.Group (Realize.Stroke stroke)) (Realize.Note stroke)

-- | Realize a Korvai on a particular instrument.
realize :: Solkattu.Notation stroke => Instrument stroke -> Bool -> Korvai
    -> [Either Error ([Flat stroke], Error)]
realize instrument realizePatterns korvai = case korvaiSections korvai of
    Sollu seqs ->
        map (realize1 (instFromSollu instrument smap) . sectionSequence) seqs
    Mridangam seqs -> case instFromMridangam instrument of
        Nothing -> [Left "no sequence, wrong instrument type"]
        Just realizeNote -> map (realize1 realizeNote . sectionSequence) seqs
    where
    realize1 realizeNote =
        fmap (first (instPostprocess instrument))
        . realizeInstrument realizePatterns realizeNote inst tala
            (korvaiEddupu korvai)
    smap = Realize.instStrokeMap inst
    tala = korvaiTala korvai
    inst = instFromStrokes instrument (korvaiStrokeMaps korvai)

realizeInstrument :: (Pretty sollu, Solkattu.Notation stroke)
    => Bool -> Realize.GetStroke sollu stroke
    -> Realize.Instrument stroke -> Tala.Tala -> S.Duration -> SequenceT sollu
    -> Either Error ([Flat stroke], Error)
realizeInstrument realizePatterns getStroke inst tala eddupu sequence = do
    realized <- Realize.formatError $
        Realize.realize pattern getStroke $ flatten sequence
    let alignError = Realize.verifyAlignment tala eddupu $ S.tempoNotes realized
    return (realized, maybe "" (\(i, msg) -> showt i <> ": " <> msg) alignError)
    -- TODO maybe put a carat in the output where the error index is
    where
    pattern
        | realizePatterns = Realize.realizePattern (Realize.instPatterns inst)
        | otherwise = Realize.keepPattern

flatten :: [S.Note g (Solkattu.Note sollu)] -> [S.Flat g (Solkattu.Note sollu)]
flatten = Solkattu.cancelKarvai . S.flatten

-- TODO broken by KorvaiType, fix this
-- vary :: (Sequence -> [Sequence]) -> Korvai -> Korvai
-- vary modify korvai = korvai
--     { korvaiSections = concatMap modify (korvaiSections korvai) }

-- * Metadata

-- | Attach some metadata to a Korvai.
data Metadata = Metadata {
    _date :: !(Maybe Calendar.Day)
    , _tags :: !Tags
    , _location :: !Location
    } deriving (Eq, Show)

-- | (module, lineNumber, variableName)
type Location = (Text, Int, Text)

instance Semigroup Metadata where
    (<>)    (Metadata date1 tags1 loc1@(mod1, _, _))
            (Metadata date2 tags2 loc2) =
        Metadata (date1 <|> date2) (tags1 <> tags2)
            (if Text.null mod1 then loc2 else loc1)
instance Monoid Metadata where
    mempty = Metadata Nothing mempty ("", 0, "")
    mappend = (<>)

instance Pretty Metadata where
    format (Metadata date tags loc) = Pretty.record "Metadata"
        [ ("date", Pretty.format date)
        , ("tags", Pretty.format tags)
        , ("location", Pretty.format loc)
        ]

newtype Tags = Tags (Map Text [Text])
    deriving (Eq, Show, Pretty)

instance Semigroup Tags where
    Tags t1 <> Tags t2 = Tags (Util.Map.mappend t1 t2)
instance Monoid Tags where
    mempty = Tags mempty
    mappend = (<>)

tag :: Text -> Text -> Tags
tag k v = Tags (Map.singleton k [v])

date :: CallStack.Stack => Int -> Int -> Int -> Calendar.Day
date y m d
    | Num.inRange 2012 2020 y && Num.inRange 1 13 m && Num.inRange 1 32 d =
        Calendar.fromGregorian (fromIntegral y) m d
    | otherwise = Solkattu.throw $ "invalid date: " <> showt (y, m, d)

-- ** infer

-- | This is called in "Solkattu.All", thanks to "Solkattu.ExtractKorvais".
--
-- It used to be called in the 'korvai' and 'mridangamKorvai' constructors, but
-- it was confusing how it wouldn't see modifications done after construction.
inferMetadata :: Korvai -> Korvai
inferMetadata = inferSections . inferKorvaiMetadata
    where
    inferSections korvai = case korvaiSections korvai of
        Sollu sections -> korvai
            { korvaiSections =
                Sollu $ map (addTags (korvaiTala korvai)) sections
            }
        Mridangam sections -> korvai
            { korvaiSections =
                Mridangam $ map (addTags (korvaiTala korvai)) sections
            }
    addTags :: Tala.Tala -> Section stroke -> Section stroke
    addTags tala section = withSectionTags (inferSectionTags tala seq) section
        where seq = mapSollu (const ()) (sectionSequence section)

inferKorvaiMetadata :: Korvai -> Korvai
inferKorvaiMetadata korvai =
    withKorvaiMetadata (mempty { _tags = inferKorvaiTags korvai }) korvai

inferKorvaiTags :: Korvai -> Tags
inferKorvaiTags korvai = Tags $ Util.Map.multimap $ concat
    [ [ ("tala", Tala._name tala)
      , ("sections", showt sections)
      , ("eddupu", pretty (korvaiEddupu korvai))
      ]
    , map ("instrument",) instruments
    ]
    where
    tala = korvaiTala korvai
    sections = case korvaiSections korvai of
        Sollu xs -> length xs
        Mridangam xs -> length xs
    -- TODO use the names from GInstrument
    instruments = concat
        [ ["mridangam" | hasInstrument korvai instMridangam]
        , ["kendang tunggal" | hasInstrument korvai instKendangTunggal]
        , ["reyong" | hasInstrument korvai instReyong]
        , ["sargam" | hasInstrument korvai instSargam]
        ]
    hasInstrument korvai get = not $ Realize.isInstrumentEmpty $
        get (korvaiStrokeMaps korvai)

inferSectionTags :: Tala.Tala -> SequenceT () -> Tags
inferSectionTags tala seq = Tags $ Map.fromList
    [ ("avartanams", [pretty $ dur / talaAksharas])
    , ("nadai", map pretty nadais)
    , ("max_speed", [pretty $ maximum (0 : speeds)])
    ]
    where
    talaAksharas = fromIntegral (Tala.tala_aksharas tala)
    dur = Solkattu.durationOf S.defaultTempo seq
    tempos = map fst $ S.tempoNotes $ flatten seq
    nadais = Seq.unique_sort $ map S._nadai tempos
    speeds = Seq.unique_sort $ map S._speed tempos


-- * types

data StrokeMaps = StrokeMaps {
    instMridangam :: Realize.Instrument Mridangam.Stroke
    , instKendangTunggal :: Realize.Instrument KendangTunggal.Stroke
    , instReyong :: Realize.Instrument Reyong.Stroke
    , instSargam :: Realize.Instrument Sargam.Stroke
    } deriving (Eq, Show)

instance Semigroup StrokeMaps where
    StrokeMaps a1 a2 a3 a4 <> StrokeMaps b1 b2 b3 b4 =
        StrokeMaps (a1<>b1) (a2<>b2) (a3<>b3) (a4<>b4)
instance Monoid StrokeMaps where
    mempty = StrokeMaps mempty mempty mempty mempty
    mappend = (<>)

instance Pretty StrokeMaps where
    format (StrokeMaps mridangam kendangTunggal reyong sargam) =
        Pretty.record "StrokeMaps"
            [ ("mridangam", Pretty.format mridangam)
            , ("kendangTunggal", Pretty.format kendangTunggal)
            , ("reyong", Pretty.format reyong)
            , ("sargam", Pretty.format sargam)
            ]


-- * print score

printInstrument :: Solkattu.Notation stroke => Instrument stroke -> Bool
    -> Korvai -> IO ()
printInstrument instrument realizePatterns korvai =
    printResults Nothing korvai $ realize instrument realizePatterns korvai

printKonnakol :: Bool -> Korvai -> IO ()
printKonnakol realizePatterns korvai =
    printResults (Just 4) korvai $ realize konnakol realizePatterns korvai

printResults :: Solkattu.Notation stroke => Maybe Int -> Korvai
    -> [Either Error ([S.Flat g (Realize.Note stroke)], Error)]
    -> IO ()
printResults overrideStrokeWidth korvai = printList . map show1
    where
    show1 (Left err) = "ERROR:\n" <> err
    show1 (Right (notes, warning)) = TextUtil.joinWith "\n"
        (Realize.format overrideStrokeWidth width tala notes)
        warning
    tala = korvaiTala korvai

width :: Int
width = 78

printList :: [Text] -> IO ()
printList [] = return ()
printList [x] = Text.IO.putStrLn x
printList xs = mapM_ print1 (zip [1..] xs)
    where
    print1 (i, x) = do
        putStrLn $ "---- " <> show i
        Text.IO.putStrLn x
