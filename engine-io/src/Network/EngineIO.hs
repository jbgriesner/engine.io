{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Parsers and encoders for the Engine.IO protocol.
module Network.EngineIO
  ( -- * Packets
    Packet(..)
  , parsePacket
  , encodePacket

    -- * Payloads
  , Payload(..)
  , parsePayload
  , encodePayload

    -- * Transport types
  , TransportType(..)
  , parseTransportType

    -- Engine.IO protocol
  , EngineIO
  , initialize
  , handler

  , getOpenSockets

    -- * ServerAPI
  , ServerAPI(..)

    -- Sockets
  , Socket
  , socketId
  , dequeueMessage
  , enqueueMessage
  ) where

import Control.Applicative
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (SomeException(SomeException), try)
import Control.Monad (forever, guard, replicateM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Loops (unfoldM)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Either (eitherT, left)
import Control.Monad.Trans.Maybe (runMaybeT)
import Data.Aeson ((.=))
import Data.Foldable (asum, for_)
import Data.Function (fix, on)
import Data.Ix (inRange)
import Data.List (foldl')
import Data.Monoid ((<>), mconcat, mempty)
import Data.Ord (comparing)
import Data.Traversable (for)

import qualified Control.Concurrent.Async as Async
import qualified Control.Concurrent.STM as STM
import qualified Data.Aeson as Aeson
import qualified Data.Attoparsec.ByteString as Attoparsec
import qualified Data.Attoparsec.ByteString.Char8 as AttoparsecC8
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as Base64
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LBS
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Vector as V
import qualified Network.WebSockets as WebSockets
import qualified System.Random.MWC as Random

--------------------------------------------------------------------------------
data PacketType = Open | Close | Ping | Pong | Message | Upgrade | Noop
  deriving (Bounded, Enum, Eq, Read, Show)


--------------------------------------------------------------------------------
parsePacketType :: Attoparsec.Parser PacketType
parsePacketType = asum $
  [ Open <$ AttoparsecC8.char '0'
  , Close <$ AttoparsecC8.char '1'
  , Ping <$ AttoparsecC8.char '2'
  , Pong <$ AttoparsecC8.char '3'
  , Message <$ AttoparsecC8.char '4'
  , Upgrade <$ AttoparsecC8.char '5'
  , Noop <$ AttoparsecC8.char '6'
  ]
{-# INLINE parsePacketType #-}


--------------------------------------------------------------------------------
encodePacketType :: PacketType -> Builder.Builder
encodePacketType t = case t of
  Open -> Builder.char8 '0'
  Close -> Builder.char8 '1'
  Ping -> Builder.char8 '2'
  Pong -> Builder.char8 '3'
  Message -> Builder.char8 '4'
  Upgrade -> Builder.char8 '5'
  Noop -> Builder.char8 '6'
{-# INLINE encodePacketType #-}


--------------------------------------------------------------------------------
data Packet = Packet !PacketType !BS.ByteString
  deriving (Eq, Show)


--------------------------------------------------------------------------------
parsePacket :: Attoparsec.Parser Packet
parsePacket = parsePacket' Attoparsec.takeByteString
{-# INLINE parsePacket #-}


--------------------------------------------------------------------------------
encodePacket :: Packet -> Builder.Builder
encodePacket (Packet t bytes) = encodePacketType t <> Builder.byteString bytes
{-# INLINE encodePacket #-}


--------------------------------------------------------------------------------
newtype Payload = Payload (V.Vector Packet)
  deriving (Eq, Show)


--------------------------------------------------------------------------------
parsePayload :: Attoparsec.Parser Payload
parsePayload = Payload <$> go
  where
  go = do
    isString <- (True <$ Attoparsec.word8 0) <|> (False <$ Attoparsec.word8 1)
    len <- parseLength =<< Attoparsec.many1 (Attoparsec.satisfy (inRange (0, 9)))
    _ <- Attoparsec.word8 maxBound

    packet <- parsePacket' (Attoparsec.take (len - 1)) -- the type consumes 1 byte
    (V.singleton packet <$ Attoparsec.endOfInput) <|> (V.cons packet <$> go)

  parseLength bytes = do
    guard (length bytes <= 319)
    return $ foldl' (\n x -> n * 10 + x) 0 $ map fromIntegral bytes


--------------------------------------------------------------------------------
encodePayload :: Payload -> Builder.Builder
encodePayload (Payload packets) =
  let contents = V.foldl' (\bytes p -> bytes <> encodePacket p) mempty packets
      l = LBS.length (Builder.toLazyByteString contents)
  in mconcat [ Builder.word8 0
             , mconcat $ map (Builder.word8 . read . pure) $ show l
             , Builder.word8 maxBound
             , contents
             ]


--------------------------------------------------------------------------------
parsePacket' :: Attoparsec.Parser BS.ByteString -> Attoparsec.Parser Packet
parsePacket' body = Packet <$> parsePacketType <*> body
{-# INLINE parsePacket' #-}


--------------------------------------------------------------------------------
data TransportType = Polling | Websocket
  deriving (Eq, Show)

instance Aeson.ToJSON TransportType where
  toJSON t = Aeson.toJSON $ (`asTypeOf` show t) $
    case t of
      Polling -> "polling"
      Websocket -> "websocket"


--------------------------------------------------------------------------------
parseTransportType :: Text.Text -> Maybe TransportType
parseTransportType t =
  case t of
    "polling" -> Just Polling
    "websocket" -> Just Websocket
    _ -> Nothing
{-# INLINE parseTransportType #-}


--------------------------------------------------------------------------------
type SocketId = BS.ByteString


--------------------------------------------------------------------------------
data Transport = Transport
  { transIn :: STM.TChan Packet
  , transOut :: STM.TChan Packet
  , transType :: !TransportType
  }


--------------------------------------------------------------------------------
data Socket = Socket
  { socketId :: !SocketId
  , socketTransport :: STM.TVar Transport
  , socketIncomingMessages :: STM.TChan BS.ByteString
  , socketOutgoingMessages :: STM.TChan BS.ByteString
  }

instance Eq Socket where
  (==) = (==) `on` socketId

instance Ord Socket where
  compare = comparing socketId


--------------------------------------------------------------------------------
dequeueMessage :: Socket -> STM.STM BS.ByteString
dequeueMessage Socket{..} = STM.readTChan socketIncomingMessages
{-# INLINE dequeueMessage #-}


--------------------------------------------------------------------------------
enqueueMessage :: Socket -> BS.ByteString -> STM.STM ()
enqueueMessage Socket{..} = STM.writeTChan socketOutgoingMessages
{-# INLINE enqueueMessage #-}


--------------------------------------------------------------------------------
data ServerAPI m = ServerAPI
  { srvGetQueryParams :: m (HashMap.HashMap BS.ByteString [BS.ByteString])
  , srvWriteBuilder :: Builder.Builder -> m ()
  , srvSetContentType :: BS.ByteString -> m ()
  , srvParseRequestBody :: forall a. Attoparsec.Parser a -> m a
  , srvGetRequestMethod :: m BS.ByteString
  , srvRunWebSocket :: WebSockets.ServerApp -> m ()
  , srvSetResponseCode :: Int -> m ()
  }


--------------------------------------------------------------------------------
data EngineIO = EngineIO
  { eioOpenSessions :: STM.TVar (HashMap.HashMap SocketId Socket)
  , eioRng :: MVar Random.GenIO
  }


--------------------------------------------------------------------------------
initialize :: IO EngineIO
initialize =
  EngineIO
    <$> STM.newTVarIO mempty
    <*> (Random.createSystemRandom >>= newMVar)


--------------------------------------------------------------------------------
getOpenSockets :: EngineIO -> STM.STM (HashMap.HashMap SocketId Socket)
getOpenSockets = STM.readTVar . eioOpenSessions


--------------------------------------------------------------------------------
data EngineIOError = BadRequest | TransportUnknown | SessionIdUnknown
  deriving (Bounded, Enum, Eq, Show)


--------------------------------------------------------------------------------
handler :: MonadIO m => EngineIO -> (Socket -> IO ()) -> ServerAPI m -> m ()
handler eio socketHandler api@ServerAPI{..} = do
  queryParams <- srvGetQueryParams
  eitherT (serveError api) return $ do
    reqTransport <- maybe (left TransportUnknown) return $ do
      [t] <- HashMap.lookup "transport" queryParams
      parseTransportType (Text.decodeUtf8 t)

    socket <-
      for (HashMap.lookup "sid" queryParams) $ \sids -> do
        sid <- case sids of
                 [sid] -> return sid
                 _ -> left SessionIdUnknown

        mSocket <- liftIO (STM.atomically (HashMap.lookup sid <$> getOpenSockets eio))
        case mSocket of
          Nothing -> left SessionIdUnknown
          Just s -> return s

    case socket of
      Just s -> do
        transport <- liftIO $ STM.atomically $ STM.readTVar (socketTransport s)
        case transType transport of
          Polling
            | reqTransport == Polling -> lift (handlePoll api transport)
            | reqTransport == Websocket -> lift (upgrade api s)

          _ -> left BadRequest

      Nothing ->
        lift (freshSession eio socketHandler api)


--------------------------------------------------------------------------------
freshSession
  :: MonadIO m
  => EngineIO
  -> (Socket -> IO ())
  -> ServerAPI m
  -> m ()
freshSession eio socketHandler api = do
  socketId <- liftIO $ do
    socketId <- newSocketId eio

    socket <- Socket <$> pure socketId
                     <*> (do transport <- Transport <$> STM.newTChanIO
                                                    <*> STM.newTChanIO
                                                    <*> pure Polling
                             STM.newTVarIO transport)
                     <*> STM.newTChanIO
                     <*> STM.newTChanIO

    brain <- Async.async $ forever $ STM.atomically $ do
      transport <- STM.readTVar (socketTransport socket)
      asum
        [ do req <- STM.readTChan (transIn transport)
             case req of
               Packet Message m ->
                 STM.writeTChan (socketIncomingMessages socket) m

               Packet Ping m ->
                 STM.writeTChan (transOut transport) (Packet Pong m)

               Packet Close m ->
                 STM.modifyTVar' (eioOpenSessions eio) (HashMap.delete socketId)

               _ -> return ()

        , STM.readTChan (socketOutgoingMessages socket)
            >>= STM.writeTChan (transOut transport) . Packet Message
        ]


    STM.atomically (STM.modifyTVar' (eioOpenSessions eio) (HashMap.insert socketId socket))

    userSpace <- Async.async (socketHandler socket)

    return socketId

  let openMessage = OpenMessage { omSocketId = socketId
                                , omUpgrades = [ Websocket ]
                                , omPingTimeout = 60000
                                , omPingInterval = 25000
                                }

      payload = Payload $ V.singleton $
                  Packet Open (LBS.toStrict $ Aeson.encode openMessage)

  writeBytes api (encodePayload payload)


--------------------------------------------------------------------------------
upgrade :: MonadIO m => ServerAPI m -> Socket -> m ()
upgrade ServerAPI{..} socket = srvRunWebSocket go

  where

  go pending = do
    conn <- WebSockets.acceptRequest pending

    mWsTransport <- runMaybeT $ do
      Packet Ping "probe" <- lift (receivePacket conn)
      lift (sendPacket conn (Packet Pong "probe"))

      (wsIn, wsOut) <- liftIO $ STM.atomically $ do
        currentTransport <- STM.readTVar (socketTransport socket)
        STM.writeTChan (transOut currentTransport) (Packet Noop BS.empty)

        wsIn <- STM.dupTChan (transIn currentTransport)
        wsOut <- STM.newTChan
        return (wsIn, wsOut)

      Packet Upgrade bytes <- lift (receivePacket conn)
      guard (bytes == BS.empty)

      return (Transport wsIn wsOut Websocket)

    for_ mWsTransport $ \wsTransport@Transport { transIn = wsIn, transOut = wsOut } -> do
      -- The client has completed the upgrade, so we can swap out the current
      -- transport with a WebSocket transport.
      STM.atomically (STM.writeTVar (socketTransport socket) wsTransport)

      reader <- Async.async $ forever $ do
        p <- STM.atomically (STM.readTChan wsOut)
        sendPacket conn p

      fix $ \loop -> do
        e <- try (receivePacket conn >>= STM.atomically . STM.writeTChan wsIn)
        case e of
          Left (SomeException e) ->
            return ()

          Right _ -> loop

      STM.atomically (STM.writeTChan wsIn (Packet Close BS.empty))
      Async.cancel reader

  receivePacket conn = do
    msg <- WebSockets.receiveDataMessage conn
    case msg of
      WebSockets.Text bytes ->
       let Right p = Attoparsec.parseOnly parsePacket (LBS.toStrict bytes)
       in return p

      other -> do
        putStrLn $ "Unknown WebSocket message: " ++ show other
        receivePacket conn

  sendPacket conn p = do
    WebSockets.sendTextData conn (Builder.toLazyByteString (encodePacket p))


--------------------------------------------------------------------------------
handlePoll :: MonadIO m => ServerAPI m -> Transport -> m ()
handlePoll api@ServerAPI{..} transport = do
  requestMethod <- srvGetRequestMethod
  case requestMethod of
    m | m == "GET" -> poll
    m | m == "POST" -> post
    _ -> serveError api BadRequest

  where

  poll = do
    let out = transOut transport
    packets <- liftIO $
      (:) <$> STM.atomically (STM.readTChan out)
          <*> unfoldM (STM.atomically (STM.tryReadTChan (transOut transport)))

    writeBytes api (encodePayload (Payload (V.fromList packets)))

  post = do
    Payload packets <- srvParseRequestBody parsePayload
    liftIO $ STM.atomically (V.mapM_ (STM.writeTChan (transIn transport)) packets)


--------------------------------------------------------------------------------
writeBytes :: Monad m => ServerAPI m -> Builder.Builder -> m ()
writeBytes ServerAPI {..} builder = do
  srvWriteBuilder builder
  srvSetContentType "application/octet-stream"
{-# INLINE writeBytes #-}


--------------------------------------------------------------------------------
newSocketId :: EngineIO -> IO SocketId
newSocketId eio =
  Base64.encode . BS.pack
    <$> withMVar (eioRng eio) (replicateM 15 . Random.uniformR (0, 63))
{-# INLINE newSocketId #-}


--------------------------------------------------------------------------------
data OpenMessage = OpenMessage
  { omSocketId :: !SocketId
  , omUpgrades :: [TransportType]
  , omPingTimeout :: !Int
  , omPingInterval :: !Int
  }

instance Aeson.ToJSON OpenMessage where
  toJSON OpenMessage {..} = Aeson.object
    [ "sid" .= Text.decodeUtf8 omSocketId
    , "upgrades" .= omUpgrades
    , "pingTimeout" .= omPingTimeout
    , "pingInterval" .= omPingInterval
    ]


--------------------------------------------------------------------------------
serveError :: Monad m => ServerAPI m -> EngineIOError -> m ()
serveError ServerAPI{..} e = do
  srvSetResponseCode 400
  srvSetContentType "application/json"
  srvWriteBuilder $ Builder.lazyByteString $ Aeson.encode $ Aeson.object
    [ "code" .= errorCode, "message" .= errorMessage ]

  where
  errorCode :: Int
  errorCode = case e of
                TransportUnknown -> 0
                SessionIdUnknown -> 1
                BadRequest -> 3

  errorMessage :: Text.Text
  errorMessage = case e of
                   TransportUnknown -> "Transport unknown"
                   SessionIdUnknown -> "Session ID unknown"
                   BadRequest -> "Bad request"