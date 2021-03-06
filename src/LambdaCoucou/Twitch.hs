module LambdaCoucou.Twitch where

import qualified Control.Concurrent.MVar as MVar
import qualified Control.Concurrent.STM.TBMChan as Chan
import qualified Control.Monad.STM as STM
import qualified Data.Aeson as JSON
import qualified LambdaCoucou.Http as LC.HTTP
import qualified LambdaCoucou.State as LC.St
import qualified LambdaCoucou.TwitchHook as Hook
import LambdaCoucou.TwitchTypes
import qualified LambdaCoucou.Url as LC.Url
import Network.HTTP.Req ((/:), (=:))
import qualified Network.HTTP.Req as Req
import qualified Network.IRC.Client as IRC.C
import qualified Network.IRC.Client.Events as IRC.Ev
import RIO
import qualified RIO.Text as T
import qualified RIO.Time as Time
import qualified System.Environment as Env
import System.IO (putStr)
import qualified UnliftIO.Async as Async

getClientCredentials ::
  (MonadIO m, MonadThrow m) =>
  ClientID ->
  ClientSecret ->
  m ClientCredentials
getClientCredentials clientID clientSecret = do
  let options =
        "client_id" =: clientID
          <> "client_secret" =: clientSecret
          <> "grant_type" =: ("client_credentials" :: Text)
  logStr "Getting twitch credentials"
  resp <-
    LC.HTTP.runFetchEx $
      Req.req
        Req.POST
        (Req.https "id.twitch.tv" /: "oauth2" /: "token")
        Req.NoReqBody
        Req.jsonResponse
        options
  now <- liftIO Time.getCurrentTime
  let ccr = Req.responseBody resp
  let expiresAt = Time.addUTCTime (fromIntegral $ ccrExpiresInSeconds ccr) now
  logStr $ "Got twitch credentials. Expire at: " <> show expiresAt
  pure $
    ClientCredentials
      { ccClientAuthToken = ccrClientAuthToken ccr,
        ccExpiresAt = expiresAt
      }

-- | returns a valid auth token. If the existing token is nearing expiration, it will be
-- replaced and the updated token will be returned
ensureClientToken :: ClientEnv -> IO ClientAuthToken
ensureClientToken ClientEnv {ceClientID, ceClientSecret, ceClientCredentials} =
  MVar.modifyMVar ceClientCredentials $ \case
    Nothing -> renewCreds
    Just creds -> do
      now <- Time.getCurrentTime
      if now >= Time.addUTCTime 10 (ccExpiresAt creds)
        then renewCreds
        else pure (Just creds, ccClientAuthToken creds)
  where
    renewCreds = do
      newCreds <- getClientCredentials ceClientID ceClientSecret
      pure (Just newCreds, ccClientAuthToken newCreds)

getSingleTwitchData ::
  (MonadIO m, MonadThrow m, JSON.FromJSON a) =>
  Text ->
  ClientID ->
  ClientAuthToken ->
  Req.Option 'Req.Https ->
  m a
getSingleTwitchData urlPath clientId token options = do
  resp <-
    LC.HTTP.runFetchEx $
      Req.req
        Req.GET
        (Req.https "api.twitch.tv" /: "helix" /: urlPath)
        Req.NoReqBody
        Req.jsonResponse
        ( Req.oAuth2Bearer (T.encodeUtf8 $ getClientAuthToken token)
            <> Req.header "Client-ID" (T.encodeUtf8 $ getClientID clientId)
            <> options
        )
  pure $ getSingleTwitchResponse $ Req.responseBody resp

getTwitchStream :: (MonadIO m, MonadThrow m) => ClientID -> ClientAuthToken -> UserLogin -> m StreamData
getTwitchStream clientId token (UserLogin userLogin) =
  getSingleTwitchData "streams" clientId token ("user_login" =: userLogin)

getTwitchUser :: (MonadIO m, MonadThrow m) => ClientID -> ClientAuthToken -> UserLogin -> m User
getTwitchUser clientId token (UserLogin userLogin) =
  getSingleTwitchData "users" clientId token ("login" =: userLogin)

subscribeToChannel :: ClientEnv -> UserID -> IO ()
subscribeToChannel env (UserID userID) =
  postWebhook Subscribe env (HubTopic $ "https://api.twitch.tv/helix/streams?user_id=" <> userID)

unsubscribeFromChannel :: ClientEnv -> UserID -> IO ()
unsubscribeFromChannel env (UserID userID) =
  postWebhook Unsubscribe env (HubTopic $ "https://api.twitch.tv/helix/streams?user_id=" <> userID)

postWebhook :: HubMode -> ClientEnv -> HubTopic -> IO ()
postWebhook hubMode env topic = do
  let lease = HubLeaseSeconds $ 3600 * 24 * 5
  let callbackUrl :: Text = "https://irc.geekingfrog.com/twitch/notifications"
  let payload =
        SubscribeParams
          { spCallback = callbackUrl,
            spMode = hubMode,
            spTopic = topic,
            spLease = lease
          }
  token <- ensureClientToken env
  void $
    LC.HTTP.runFetchEx $
      Req.req
        Req.POST
        (Req.https "api.twitch.tv" /: "helix" /: "webhooks" /: "hub")
        (Req.ReqBodyJson payload)
        Req.bsResponse
        ( Req.oAuth2Bearer (T.encodeUtf8 $ getClientAuthToken token)
            <> Req.header "Client-ID" (T.encodeUtf8 $ getClientID $ ceClientID env)
        )
  logStr $ "subscription request sent: " <> show payload

startWatchChannel :: ClientEnv -> StreamWatcherSpec -> IO ()
startWatchChannel env spec = do
  token <- ensureClientToken env
  twitchUser <- getTwitchUser (ceClientID env) token (swsTwitchUserLogin spec)
  unsubscribeFromChannel env (usrID twitchUser)
  threadDelay (5 * 10 ^ 6)
  subscribeToChannel env (usrID twitchUser)
  logStr $ "subscribed to channel for twitch user: " <> show twitchUser
  pure ()

makeClientEnv :: IO ClientEnv
makeClientEnv = do
  clientID <- ClientID . T.pack <$> getEnv "TWITCH_CLIENT_ID"
  clientSecret <- ClientSecret . T.pack <$> getEnv "TWITCH_CLIENT_SECRET"
  Just port <- readMaybe <$> getEnv "TWITCH_WEBHOOK_SERVER_PORT"
  creds <- MVar.newMVar Nothing
  leases <- MVar.newMVar []
  chan <- Chan.newTBMChanIO 1
  pure $
    ClientEnv
      { ceClientID = clientID,
        ceClientSecret = clientSecret,
        ceClientCredentials = creds,
        ceWebhookServerPort = port,
        ceNotificationLeases = leases,
        ceNotifChan = chan
      }
  where
    getEnv e =
      Env.lookupEnv e >>= \case
        Nothing -> throwString $ "Missing " <> e
        Just s -> pure s

processNotifications ::
  [StreamWatcherSpec] ->
  Chan.TBMChan StreamNotification ->
  IRC.C.IRC LC.St.CoucouState ()
processNotifications specs chan = loop
  where
    loop =
      liftIO (STM.atomically (Chan.readTBMChan chan)) >>= \case
        Nothing -> logStr "notification channel closed"
        Just notif -> do
          logStr $ "got a notification: " <> show notif
          case notif of
            StreamOffline -> loop
            StreamOnline streamData ->
              case filter
                ( \s ->
                    CaseInsensitive (swsTwitchUserLogin s)
                      == CaseInsensitive (sdUserName streamData)
                )
                specs of
                [] -> loop
                (x : _) -> do
                  let streamUrl = "https://www.twitch.tv/" <> getUserLogin (sdUserName streamData)
                  let str = "Le stream de " <> swsIRCNick x <> " est maintenant live ! " <> streamUrl
                  let chan = swsIRCChan x
                  let msg = IRC.Ev.Privmsg chan (Right str)
                  IRC.C.send msg
                  LC.Url.updateLastUrl (LC.St.ChannelName chan) streamUrl
                  loop

-- | every 10 minutes, check if leases are expiring soon, if yes, renew them
watchLeases :: ClientEnv -> IO ()
watchLeases env = forever $ do
  threadDelay (intervalInSeconds * 10 ^ 6)
  now <- Time.getCurrentTime
  leasesSoonToExpire <- filter (leaseExpiresAfter now intervalInSeconds) <$> MVar.readMVar envLeases
  forM_ leasesSoonToExpire $ \l -> do
    logStr $ "Renewing lease: " <> show l
    postWebhook Subscribe env (leaseTopic l)
  when (null leasesSoonToExpire) $ logStr "no twitch lease to renew"
  where
    envLeases = ceNotificationLeases env
    intervalInSeconds = 60 * 10

leaseExpiresAfter :: Time.UTCTime -> Int -> Lease -> Bool
leaseExpiresAfter now intervalInSeconds lease =
  Time.addUTCTime (fromIntegral intervalInSeconds) now >= leaseExpiresAt lease

watchStreams ::
  IRC.C.IRCState LC.St.CoucouState ->
  MVar.MVar (Maybe ClientEnv) ->
  IO ()
watchStreams botState clientEnvMvar = do
  env <- liftIO makeClientEnv
  MVar.swapMVar clientEnvMvar (Just env)
  let specs =
        [ StreamWatcherSpec
            { swsTwitchUserLogin = UserLogin "artart78",
              swsIRCNick = "artart78",
              swsIRCChan = "#arch-fr-free"
            },
          StreamWatcherSpec
            { swsTwitchUserLogin = UserLogin "gikiam",
              swsIRCNick = "gikiam",
              swsIRCChan = "#arch-fr-free"
            },
          StreamWatcherSpec
            { swsTwitchUserLogin = UserLogin "geekingfrog",
              swsIRCNick = "Geekingfrog",
              swsIRCChan = "#arch-fr-free"
            },
          StreamWatcherSpec
            { swsTwitchUserLogin = UserLogin "shampooingonthemove",
              swsIRCNick = "Shampooing",
              swsIRCChan = "#arch-fr-free"
            }
        ]
  Async.runConc $
    Async.conc (IRC.C.runIRCAction (processNotifications specs (ceNotifChan env)) botState)
      <> Async.conc (traverse_ (startWatchChannel env) specs)
      <> Async.conc (Hook.runWebhookServer env)
      <> Async.conc (watchLeases env)
  logStr "Not watching streams anymore"

iso8601 :: Time.UTCTime -> String
iso8601 = Time.formatTime Time.defaultTimeLocale "%FT%T%QZ"

logStr :: (MonadIO m) => String -> m ()
logStr msg = liftIO $ do
  now <- Time.getCurrentTime
  putStr $ iso8601 now <> " " <> msg <> "\n"

processTest :: ClientEnv -> IO ()
processTest env = loop
  where
    loop =
      STM.atomically (Chan.readTBMChan $ ceNotifChan env) >>= \case
        Nothing -> logStr "channel closed"
        Just n -> do
          logStr $ "got notification:" <> show n
          loop

test :: IO ()
test = do
  clientID <- ClientID . T.pack <$> Env.getEnv "TWITCH_CLIENT_ID"
  clientSecret <- ClientSecret . T.pack <$> Env.getEnv "TWITCH_CLIENT_SECRET"
  getClientCredentials clientID clientSecret >>= logStr . show
  -- error "coucou"
  env <- makeClientEnv
  -- let specs =
  --       [ StreamWatcherSpec
  --           { swsTwitchUserLogin = UserLogin "artart78",
  --             swsIRCNick = "artart78",
  --             swsIRCChan = "#arch-fr-free"
  --           },
  --         StreamWatcherSpec
  --           { swsTwitchUserLogin = UserLogin "geekingfrog",
  --             swsIRCNick = "geekingfrog",
  --             swsIRCChan = "#gougoutest"
  --           },
  --         StreamWatcherSpec
  --           { swsTwitchUserLogin = UserLogin "gikiam",
  --             swsIRCNick = "gikiam",
  --             swsIRCChan = "#arch-fr-free"
  --           }
  --       ]

  let specs =
        [ StreamWatcherSpec
            { swsTwitchUserLogin = UserLogin "geekingfrog",
              swsIRCNick = "geekingfrog",
              swsIRCChan = "#gougoutest"
            }
        ]
  Async.runConc $
    Async.conc (traverse_ (startWatchChannel env) specs)
      <> Async.conc (processTest env)
      <> Async.conc (Hook.runWebhookServer env)
  -- getClientCredentials clientID clientSecret >>= print
  -- getTwitchStream clientAuthToken stream >>= print
  -- getTwitchUser clientAuthToken (UserLogin "gikiam") >>= print
  logStr "test all done"
