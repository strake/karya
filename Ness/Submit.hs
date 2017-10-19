module Ness.Submit where
import qualified Data.Aeson as Aeson
import Data.Aeson ((.:))
import qualified Data.Aeson.Types as Aeson.Types
import qualified Data.ByteString.Lazy as ByteString.Lazy
import qualified Data.ByteString.Lazy.Char8 as ByteString.Lazy.Char8
import qualified Data.Text as Text
import qualified Data.Time as Time

import qualified System.Environment
import qualified System.Exit as Exit
import qualified System.Process as Process

import qualified Util.ParseText as ParseText
import qualified Util.Thread as Thread
import Global


loginForm :: Url
-- loginForm = "https://www.ease.ed.ac.uk/"
loginForm = "https://www.ease.ed.ac.uk/\
    \?cosign-eucsCosign-ness-frontend.epcc.ed.ac.uk\
    \&https://ness-frontend.epcc.ed.ac.uk/~pgraham/NUI/Web/nuiWebMain.html"

loginUrl :: Url
loginUrl = "https://www.ease.ed.ac.uk/cosign.cgi"

cookies :: FilePath
cookies = "ness-data/cookies"

-- post
-- enctype="application/x-www-form-urlencoded"
--
-- login=qdunkan@gmail.com password=***
-- ref=https://ness-frontend.epcc.ed.ac.uk/~pgraham/NUI/Web/nuiWebMain.html
-- service=cosign-eucsCosign-ness-frontend.epcc.ed.ac.uk

submitUrl :: Url
submitUrl =
    "https://ness-frontend.epcc.ed.ac.uk/~pgraham/NUI/Web/nuiZCRemoteRunner.php"

main :: IO ()
main = do
    [instrument, score, out] <- System.Environment.getArgs
    submitDownload False instrument score out
    return ()

type Url = String

submitDownload :: Bool -> FilePath -> FilePath -> FilePath -> IO (Bool, Url)
submitDownload isDemo instrument score out = do
    (url, estimatedTime) <- submit isDemo instrument score
    putStrLn $ "=== response: " ++ url
    putStrLn $ "=== run time: " ++ show estimatedTime
    Thread.delay $ realToFrac estimatedTime
    ok <- download 5 out url
    unless ok $ putStrLn "=== gave up"
    return (ok, url)

-- TODO I get a cosign=xyz cookie, and get "logged in but no access to service"
-- I should get a cosign-eucsCosign-ness-frontend etc.
-- is it ignoring the service= in the login?
login :: String -> String -> IO ()
login user password = do
    -- go to loginForm, to get the cosign cookie
    Process.callProcess "curl"
        [ "--cookie-jar", cookies
        , "--output", "curl.loginForm"
        , loginForm
        ]
    let values =
            [ ("ref", "https://ness-frontend.epcc.ed.ac.uk/\
                \~pgraham/NUI/Web/nuiWebMain.html")
            , ("service", "cosign-eucsCosign-ness-frontend.epcc.ed.ac.uk")
            , ("login", user)
            , ("password", password)
            ]
    Process.callProcess "curl" $
        [ "--insecure"
        , "--verbose"
        , "--cookie", cookies
        , "--cookie-jar", cookies
        , "--output", "curl.login"
        -- follow the location response to pick up the next cookie
        , "--location"
        ] ++ concat [["--data-raw", k <> "=" <> v] | (k, v) <- values]
        ++ [loginUrl]

submit :: Bool -> FilePath -> FilePath -> IO (Url, Double)
    -- ^ (urlWithResult, estimatedTime)
submit isDemo instrument score = do
    putStrLn $ "=== submit " ++ show (instrument, score)
    json <- Process.readProcess "curl"
        [ "--insecure"
        , "--cookie", cookies
        , "--form", "scorefile=@" <> score
        , "--form", "instrfile=@" <> instrument
        , "--form", "booleanDemo=" <> if isDemo then "true" else "false"
        -- , "--verbose"
        , submitUrl
        ]
        ""
    -- writeFile "ness-data/submit.result" json
    either (errorIO . txt) return $ parseJson $ ByteString.Lazy.Char8.pack json

download :: Double -> FilePath -> Url -> IO Bool
download timeout out url = go =<< Time.getCurrentTime
    where
    go start = ifM (poll out url) (return True) $ do
        now <- Time.getCurrentTime
        let elapsed = realToFrac (now `Time.diffUTCTime` start)
        if elapsed > timeout
            then return False
            else do
                putStrLn $ "elapsed " <> prettys elapsed <> " < "
                    <> prettys timeout
                Thread.delay 2
                go start

poll :: FilePath -> Url -> IO Bool
poll out url = do
    exit <- Process.waitForProcess =<< Process.spawnProcess "curl"
        [ "--insecure"
        , "--cookie", cookies
        , "--output", out
        -- , "--verbose"
        , "--fail" -- exit failure on 404
        , url
        ]
    return $ exit == Exit.ExitSuccess

type Error = String

formatError dir text html = untxt $ Text.unlines
    [ "=== dir: " <> dir
    , Text.replace "/localdisk/home/pgraham/PaulJGraham/NUI/BackEnd/" "" $
        Text.replace "\\/" "/" $
        text
    , "=== html"
    , html
    ]

-- keys: ['runTextOutput', 'runMode', 'serverMixWav', runExitStatus: Int,
-- serverError: Bool, 'serverResultDir', 'runEstRunTime', 'serverHtmlOutput']
-- runTextOutput or serverHtmlOutput
parseJson :: ByteString.Lazy.ByteString -> Either Error (Url, Double)
parseJson json = do
    json <- justErr ("json: " <> show json) $ Aeson.decode json
    flip Aeson.Types.parseEither json $ \obj -> do
        status <- obj .: "runExitStatus"
        serverError <- obj .: "serverError"
        if status == (1 :: Int) || serverError
            then do
                dir <- obj .: "serverResultDir"
                text <- obj .: "runTextOutput"
                html <- obj .: "serverHtmlOutput"
                fail $ formatError dir text html
            else do
                dir <- obj .: "serverResultDir"
                time <- obj .: "runEstRunTime"
                return
                    ( dir <> "/output-mix.wav"
                    , fromMaybe 0 $ ParseText.float time
                    )
