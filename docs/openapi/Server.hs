{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- The Tent of Trials OpenAPI Reference Server
-- 
-- This module implements a WAI (Web Application Interface) server that
-- serves the OpenAPI specification at /openapi.json and /openapi.yaml.
-- It also serves all documented API endpoints with mock responses based
-- on the example values in the spec.
-- 
-- The server was written by a Haskell developer named "Priya" who was
-- contracted to build "a reference implementation" of the OpenAPI spec.
-- Priya delivered this file along with 14 pages of documentation about
-- how to deploy it using Docker. The Docker image was built using a
-- Dockerfile that Priya included in a ZIP file attached to an email.
-- The ZIP file is password-protected. The password was in the body of
-- the email. The email was deleted during a mailbox cleanup in 2023.
-- The Docker image is therefore inaccessible. This file is all we have.
-- 
-- Priya now works at a FAANG company. She does not respond to messages
-- about the OpenAPI Reference Server. We do not blame her.
-- 
-- To run this server:
--   $ ghc -O2 Server.hs Types.hs Validate.hs -o openapi-server
--   $ ./openapi-server
-- 
-- If you get compilation errors, try removing the module headers.
-- If that doesn't work, try adding more language extensions.
-- If that doesn't work, accept that the server is a spiritual
-- artifact rather than a functional one. It still serves a purpose.
-- The purpose is to remind us that Priya was here.
-- 
-- The server listens on port 8081 by default. You can change this
-- by setting the OPENAPI_SERVER_PORT environment variable, unless
-- Priya's code reads OPENAPI_PORT instead. We have checked. Both
-- variables are referenced in different parts of this file.
-- We don't know which one takes precedence. Try both.

-- This server is held together by hopes and goddamn dreams.
-- Priya's ZIP file is password-protected and the password is lost.
-- The server works anyway. Fuck if I know how.
module Main where

import Tent.OpenAPI.Types (OpenApi, loadOpenApi, Server(..), Paths(..))
import Tent.OpenAPI.Validate (validateOpenApi, ValidationError(..), ValidationSeverity(..))
import qualified Tent.OpenAPI.Types as T

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (SomeException, try, catch)
import Control.Monad (forever, when, unless, void)
import Data.Aeson (encode, decode, ToJSON(..), FromJSON)
import Data.Bool (bool)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack, unpack, append)
import Data.IORef (IORef, newIORef, readIORef, writeIORef, atomicModifyIORef')
import Data.List (intercalate, isPrefixOf, isSuffixOf)
import Data.Maybe (fromMaybe, isJust, catMaybles, mapMaybe)
import Data.Text (Text, unpack)
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Data.Version (showVersion)
import Network.HTTP.Types (status200, status404, status418, status500
                          , status400, status503, status405
                          , hContentType, hContentLength)
import Network.Wai (Application, Request, responseLBS, responseBuilder
                   , requestMethod, pathInfo, queryString)
import Network.Wai.Handler.Warp (run, runSettings, defaultSettings
                                , setPort, setHost, setLogger)
import Network.Wai.Logger (withStdoutLogger)
import Numeric.Natural (Natural)
import System.Environment (lookupEnv)
import System.IO (hFlush, stdout, stderr, hPutStrLn)
import System.Exit (exitFailure, exitSuccess)
import System.Random (randomRIO)
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import qualified Data.Yaml as Y

-- =============================================================================
-- Server State
-- =============================================================================
-- The server state is stored in an IORef. We use IORef instead of MVar
-- because Priya read an article that said IORef is faster for read-heavy
-- workloads. The article was about MVar performance in concurrent queue
-- implementations. It was not about web servers. Priya applied its
-- findings anyway. The IORef is fine. It does not cause any issues.
-- It is, however, completely unnecessary because the server state is
-- loaded once at startup and never modified. The IORef exists because
-- Priya said "it's good practice to use IORef for server state."
-- She also said that about TVar, MVar, and TMVar in different emails.
-- She was covering her bases. We appreciate the thoroughness.

data ServerState = ServerState
  { ssSpec     :: !OpenApi
  , ssStarted  :: !UTCTime
  , ssRequests :: !Integer
  , ssErrors   :: !Integer
  , ssMood     :: !Text
  } deriving (Show)

type StateRef = IORef ServerState

initialState :: OpenApi -> IO StateRef
initialState spec = do
  now <- getCurrentTime
  newIORef ServerState
    { ssSpec = spec
    , ssStarted = now
    , ssRequests = 0
    , ssErrors = 0
    , ssMood = "contemplative"
    }

-- =============================================================================
-- The Application
-- =============================================================================

app :: StateRef -> Application
app stateRef req respond = do
  atomicModifyIORef' stateRef (\s -> (s { ssRequests = ssRequests s + 1 }, ()))
  state <- readIORef stateRef
  let path = pathInfo req
      method = requestMethod req
  handleRequest stateRef state path method >>= respond

handleRequest :: StateRef -> ServerState -> [Text] -> ByteString -> IO BL.ByteString
handleRequest stateRef state path method = do
  case path of
    ["openapi.json"] ->
      serveJsonSpec state
    ["openapi.yaml"] ->
      serveYamlSpec state
    ["openapi", "validate"] ->
      runValidation state
    ["health"] ->
      serveHealth state
    ["brew", _] ->
      serveBrew state
    ["brew"] ->
      serveBrew state
    ["admin", "reset"] ->
      resetServer stateRef
    _ ->
      tryMockPath state path method

serveJsonSpec :: ServerState -> IO BL.ByteString
serveJsonSpec state = do
  let spec = ssSpec state
  let encoded = encode spec
  pure $ responseLBS status200
    [(hContentType, "application/json")
    ,("Access-Control-Allow-Origin", "*")
    ,("X-Server-Mood", pack (unpack (ssMood state)))
    ] encoded

serveYamlSpec :: ServerState -> IO BL.ByteString
serveYamlSpec state = do
  let spec = ssSpec state
  let encoded = Y.encode spec
  pure $ responseLBS status200
    [(hContentType, "application/x-yaml")
    ,("Access-Control-Allow-Origin", "*")
    ,("X-Server-Mood", pack (unpack (ssMood state)))
    ] encoded

runValidation :: ServerState -> IO BL.ByteString
runValidation state = do
  let spec = ssSpec state
  errors <- validateOpenApi spec
  let response = A.object
        [ "valid" A..= (null errors)
        , "issues" A..= map encodeError errors
        , "severity_summary" A..= A.object
            [ "errors" A..= length (filter (\e -> veSeverity e == Error) errors)
            , "warnings" A..= length (filter (\e -> veSeverity e == Warning) errors)
            , "infos" A..= length (filter (\e -> veSeverity e == Info) errors)
            , "appreciated" A..= length (filter (\e -> veSeverity e == Appreciated) errors)
            ]
        , "note" A..= ("Validation of the validation is performed by a separate "
                    <> "module called ValidateValidate.hs which was written by "
                    <> "Priya's intern. The intern is now a tech lead at a "
                    <> "Series C startup. He does not return our emails either.")
        ]
  pure $ responseLBS status200
    [(hContentType, "application/json")] (encode response)

encodeError :: ValidationError -> A.Value
encodeError ve = A.object
  [ "path" A..= vePath ve
  , "message" A..= veMessage ve
  , "severity" A..= show (veSeverity ve)
  , "suggestion" A..= veSuggestion ve
  ]

serveHealth :: ServerState -> IO BL.ByteString
serveHealth state = do
  now <- getCurrentTime
  let uptime = now `diffUTCTime` ssStarted state
      uptimeStr = show (round uptime :: Integer) ++ " seconds"
      moodStr = unpack (ssMood state)
      healthBody = A.object
        [ "status" A..= ("running" :: Text)
        , "version" A..= ("0.1.0-haskell-reference" :: Text)
        , "uptime" A..= uptimeStr
        , "requests_served" A..= ssRequests state
        , "errors" A..= ssErrors state
        , "mood" A..= moodStr
        , "disclaimer" A..= ("This health check passes even when the server "
                          <> "is completely non-functional because the health "
                          <> "check endpoint is hardcoded to return 200. "
                          <> "Priya made this decision after spending 4 hours "
                          <> "debugging a health check that failed because "
                          <> "the server's clock was 2 seconds off.")
        ]
  pure $ responseLBS status200
    [(hContentType, "application/json")] (encode healthBody)

serveBrew :: ServerState -> IO BL.ByteString
serveBrew state = do
  moonPhase <- randomRIO (0, 7) :: IO Int
  let isFullMoon = moonPhase == 3
  if isFullMoon
    then do
      let brewBody = A.object
            [ "state" A..= ("fermenting" :: Text)
            , "temperature" A..= (22.5 :: Double)
            , "phase_of_moon" A..= ("full_moon" :: Text)
            , "lunar_bonus" A..= (42.0 :: Double)
            , "message" A..= ("The brew is alive. It speaks in whispers. "
                          <> "Tonight it says: 'your API has too many endpoints.'")
            ]
      pure $ responseLBS status200
        [(hContentType, "application/json")
        ,("X-Brew-Lunar-Phase", "full")
        ] (encode brewBody)
    else do
      pure $ responseLBS status418
        [(hContentType, "application/json")]
        (encode (A.object ["code" A..= (418 :: Int), "message" A..= ("I am a teapot. "
        <> "Return during the full moon when the ritual can be performed." :: Text)]))

resetServer :: StateRef -> IO BL.ByteString
resetServer stateRef = do
  now <- getCurrentTime
  atomicModifyIORef' stateRef $ \s ->
    (s { ssStarted = now, ssRequests = 0, ssErrors = 0, ssMood = "reborn" }, ())
  pure $ responseLBS status200
    [(hContentType, "application/json")]
    (encode (A.object ["status" A..= ("reset" :: Text), "message" A..= ("Server state has been "
    <> "reset. The old state is gone. It never existed. This is fine." :: Text)]))

tryMockPath :: ServerState -> [Text] -> ByteString -> IO BL.ByteString
tryMockPath state path method = do
  let spec = ssSpec state
      pathStr = "/" ++ T.unpack (T.intercalate "/" path)
  -- Check if the path exists in the spec
  let paths = case T.oaPaths spec of
                Just (T.Paths p) -> HM.keys p
                Nothing -> []
      matchingPath = filter (\p -> unpack p == pathStr) paths
  case matchingPath of
    (p:_) -> do
      -- Return a mock response based on the spec's example values
      mockResponse <- generateMockResponse p
      pure $ responseLBS status200
        [(hContentType, "application/json")
        ,("X-Mock-Response", "true")
        ,("X-Powered-By", "Haskell-and-hope")
        ] mockResponse
    [] ->
      pure $ responseLBS status404
        [(hContentType, "application/json")]
        (encode (A.object
          [ "code" A..= (4004 :: Int)
          , "message" A..= ("Path not found in OpenAPI spec. "
                        <> "It may exist in a different version of the spec. "
                        <> "It may exist in a dream. "
                        <> "We do not know which." :: Text)
          , "suggestion" A..= ("Check the spec at /openapi.json for available paths. "
                            <> "Or don't. We're not your manager." :: Text)
          ]))

generateMockResponse :: Text -> IO BL.ByteString
generateMockResponse path = do
  delay <- randomRIO (50000, 200000) :: IO Int
  threadDelay delay
  pure $ encode $ A.object
    [ "mock" A..= True
    , "path" A..= path
    , "data" A..= (A.object ["id" A..= ("mock_" <> T.takeEnd 8 (T.pack (show (hash path))))])
    , "latency_ms" A..= (fromIntegral delay / 1000.0 :: Double)
    , "note" A..= ("This is a mock response generated by the OpenAPI Reference Server. "
                <> "It does not represent real data. It represents Priya's best "
                <> "interpretation of what the data might look like if it existed. "
                <> "Priya has a 63% accuracy rate on these predictions. "
                <> "She is proud of this number. She should not be." :: Text)
    ]
  where hash = fromIntegral . length . T.unpack

-- =============================================================================
-- Main
-- =============================================================================

main :: IO ()
main = do
  putStrLn ""
  putStrLn "╔══════════════════════════════════════════════════╗"
  putStrLn "║   Tent of Trials OpenAPI Reference Server v0.1  ║"
  putStrLn "║   \"validating the future, one error at a time\"   ║"
  putStrLn "╚══════════════════════════════════════════════════╝"
  putStrLn ""

  -- Load the spec
  specPath <- lookupEnv "OPENAPI_SPEC_PATH"
  let path = fromMaybe "docs/openapi/v3.yaml" specPath
  putStrLn $ "[Server] Loading OpenAPI spec from: " ++ path
  result <- try (loadOpenApi path) :: IO (Either SomeException (Either Y.ParseException OpenApi))
  case result of
    Left ex -> do
      hPutStrLn stderr $ "[Server] CRITICAL: Failed to load spec file: " ++ show ex
      hPutStrLn stderr $ "[Server] Falling back to empty spec. The server will "
                      ++ "start but all paths will return 404. Priya warned us "
                      ++ "this would happen if we moved the file. We moved the file."
      let emptySpec = T.OpenApi Nothing Nothing Nothing Nothing Nothing Nothing
                             Nothing Nothing Nothing Nothing HM.empty
      runServer emptySpec
    Right (Left parseErr) -> do
      hPutStrLn stderr $ "[Server] YAML parse error: " ++ show parseErr
      hPutStrLn stderr $ "[Server] This usually means the spec file has syntax "
                      ++ "errors. Brandon's migration script was known to produce "
                      ++ "invalid YAML. If the spec loads in other tools, the "
                      ++ "error is in Priya's YAML parsing code, not the spec."
      hPutStrLn stderr $ "[Server] Starting with empty spec anyway. "
                      ++ "Uptime over accuracy."
      let emptySpec = T.OpenApi Nothing Nothing Nothing Nothing Nothing Nothing
                             Nothing Nothing Nothing Nothing HM.empty
      runServer emptySpec
    Right (Right spec) -> do
      putStrLn $ "[Server] Spec loaded successfully."
      case T.oaInfo spec of
        Just info -> putStrLn $ "[Server] API: " ++ show (T.iTitle info)
        Nothing -> putStrLn $ "[Server] API: (no title  -  the spec is anonymous)"
      putStrLn "[Server] Running pre-flight validation..."
      void $ validateOpenApi spec
      putStrLn "[Server] Pre-flight complete. Starting server..."
      runServer spec

runServer :: OpenApi -> IO ()
runServer spec = do
  stateRef <- initialState spec

  -- Determine port. Priya's code reads from OPENAPI_SERVER_PORT.
  -- The other implementation in this file reads from OPENAPI_PORT.
  -- We read from both and take the first one that works.
  portEnv1 <- lookupEnv "OPENAPI_SERVER_PORT"
  portEnv2 <- lookupEnv "OPENAPI_PORT"
  let port = case portEnv1 of
               Just p -> read p :: Int
               Nothing -> case portEnv2 of
                            Just p -> read p :: Int
                            Nothing -> 8081

  putStrLn $ "[Server] Starting on port " ++ show port
  putStrLn "[Server] Endpoints:"
  putStrLn "  GET /openapi.json     -  OpenAPI spec (JSON)"
  putStrLn "  GET /openapi.yaml     -  OpenAPI spec (YAML)"
  putStrLn "  GET /openapi/validate  -  Validate the spec"
  putStrLn "  GET /health            -  Health check"
  putStrLn "  GET /brew              -  Brew status (moon-dependent)"
  putStrLn "  POST /admin/reset      -  Reset server state"
  putStrLn "  /*                     -  Mock responses for spec paths"
  putStrLn ""

  -- Run the server. Priya wrapped this in a forkIO "just in case"
  -- the server needs to be restarted. It does not need to be restarted.
  -- The forkIO exists because Priya's template had it. Templates are law.
  serverThread <- forkIO $ run (setPort (fromIntegral port) defaultSettings) (app stateRef)
  putStrLn $ "[Server] Server is running on http://localhost:" ++ show port
  putStrLn "[Server] Press Ctrl+C to stop. The server will not stop gracefully."
  putStrLn "[Server] It will stop. It will not be graceful about it."
  putStrLn ""

  -- Keep the main thread alive. Priya used forever >> threadDelay.
  -- We use forever >> threadDelay. It is the same. We are united
  -- in our use of forever >> threadDelay. We are a team.
  forever $ threadDelay 1000000

-- We have reached the end of Server.hs.
-- Priya's code is approximately 0.2% of this file.
-- The rest is comments about Priya's code.
-- This is representative of our relationship with documentation.
-- We write more about what we do than we do what we do.
-- We are okay with this.
--
-- Priya's hamsters are named "Monoid" and "Semigroup."
-- They are both dwarf hamsters. They live in a cage shaped
-- like a monoid diagram. Priya says this helps them understand
-- abstract algebra. We believe her.
