{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Main where

import Web.Spock
import Web.Spock.Config

import Control.Applicative
import Control.Monad.Logger (LoggingT, runStdoutLoggingT)
import Control.Monad.Trans
import Data.Aeson hiding (json)
import Data.IORef
import Data.Monoid ((<>))
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import Database.Persist hiding (get)
import qualified Database.Persist as P
import Database.Persist.Sqlite hiding (get)
import Database.Persist.TH

data MySession =
  EmptySession

newtype MyAppState =
  DummyAppState (IORef Int)

share
  [mkPersist sqlSettings, mkMigrate "migrateAll"]
  [persistLowerCase|
Link json
  name       T.Text
  url        T.Text
  hits       Int default=0
  created_at UTCTime default=CURRENT_TIMESTAMP
  UniqueN    name
  UniqueU    url
  deriving Show
|]

type Api = SpockM SqlBackend MySession () ()

type ApiAction a = SpockAction SqlBackend MySession () a

runSQL ::
     (HasSpock m, SpockConn m ~ SqlBackend)
  => SqlPersistT (LoggingT IO) a
  -> m a
runSQL action = runQuery $ \conn -> runStdoutLoggingT $ runSqlConn action conn

errorJson :: Int -> T.Text -> ApiAction ()
errorJson code message =
  json $
  object
    [ "result" .= String "failure"
    , "error" .= object ["code" .= code, "message" .= message]
    ]

main :: IO ()
main = do
  pool <- runStdoutLoggingT $ createSqlitePool "db/links.db" 5
  spockCfg <- defaultSpockCfg EmptySession (PCPool pool) ()
  runStdoutLoggingT $ runSqlPool (runMigration migrateAll) pool
  runSpock 80 (spock spockCfg app)

app :: Api
app = do
  get root $ do
    toplinks <- runSQL $ selectList [] [Desc LinkHits, LimitTo 30]
    json $ object ["result" .= String "success", "links" .= toplinks]
  get "links" $ redirect "/"
  post "links" $ do
    maybeLink <- jsonBody' :: ApiAction (Maybe Link)
    case maybeLink of
      Nothing -> errorJson 1 "Failed to parse request body as Link"
      Just theLink -> do
        newID <- runSQL $ insert theLink
        json $ object ["result" .= String "success", "id" .= newID]
  get ("links" <//> var <//> "delete") $ \linkName -> do
    delLink <- runSQL $ deleteWhere [LinkName ==. linkName]
    json $ object ["result" .= String "success", "name" .= linkName]
  -- The 2d value must be a HTTP escaped URL
  get ("links" <//> var <//> "edit" <//> var) $ \linkName linkURL -> do
    editLink <-
      runSQL $ updateWhere [LinkName ==. linkName] [LinkUrl =. linkURL]
    json $ object ["result" .= String "success", "id" .= linkName]
  get var $ \linkName -> do
    maybeLink <- runSQL $ selectFirst [LinkName ==. linkName] []
    case maybeLink of
      Nothing -> errorJson 2 "No record found"
      Just theLink -> do
        let theURL = linkUrl $ entityVal theLink
        redirect theURL
