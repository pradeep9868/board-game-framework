-- Copyright 2020 Nik Silver
--
-- Licensed under the GPL v3.0. See file LICENSE for details.


module BoardGameFramework exposing (
  -- Game IDs
  GameId, gameId, fromGameId , idGenerator
  -- Server connection
  , Server, wsServer, wssServer, withPort, Address, withGameId, toUrlString
  -- Open, send close
  , open, send, close
  -- Receiving messages
  , ClientId, Envelope(..), Connectivity(..)
  , decode, decoder
  )

{-| Types and functions help create remote multiplayer board games
using the related framework. See
[the detailed documentation and example
code](https://github.com/niksilver/board-game-framework/tree/master/docs)
for a proper introduction.

# Game IDs
Players with the same game ID (on the same server) are playing the same game.
@docs GameId, gameId, fromGameId, idGenerator

# Server connection
@docs Server, wsServer, wssServer, withPort, withGameId, Address, toUrlString

# Basic actions: open, send, close
@docs open, send, close

# Receiving messages
We receive envelopes: either messages from other clients, or messages from
the server about leavers and joiners, or messages about connectivity.
Any game messages sent out are encoded into JSON, so we need to say
how to decode our application's JSON messages into some suitable Elm type.
@docs ClientId, Envelope, Connectivity, Error, decode, receive
-}


import String
import Random
import Json.Encode as Enc
import Json.Decode as Dec
import Result
import Url exposing (Url)

import Words


-- Game IDs


{-| A game ID represents a game that multiple players can join.
It's a string intended to be shared among intended players.
-}
type GameId = GameId String


{-| Turn a string into a game ID.
A good game ID will have a good chance of being unique and wil be easy
to communicate, especially in URLs.
This test passes if it's five to thirty characters long (inclusive)
and consists of just alphanumerics, dots, dashes, and forward slashes.

    gameId "pancake-road"            == Ok ...
    gameId "backgammon/pancake-road" == Ok ...
    gameId "#345#"                   == Err "Bad characters"
    gameId "road"                    == Err "Too short"
-}
gameId : String -> Result String GameId
gameId str =
  let
    goodChar c =
      Char.isAlphaNum c || c == '-' || c == '.' || c == '/'
  in
  if String.length str < 5 then
    Err "Game ID too short"
  else if String.length str > 30 then
    Err "Game ID too long"
  else if String.all goodChar str then
    Ok (GameId str)
  else
    Err "Bad characters in game ID"


{-| Extract the game ID as a string.
-}
fromGameId : GameId -> String
fromGameId (GameId str) =
  str


{-| A random name generator for game IDs, which will be of the form
"_word_-_word_".

To create a `Cmd` that generates a random name, we can use code like this:

    import Random
    import BoardGameFramework as BGF

    -- Make sure our Msg can handle a generated game id
    Msg =
      ...
      | GeneratedGameId BGF.GameId
      | ...

    -- Our update function
    update : Msg -> Model -> (Model, Cmd)
    update msg model =
      case msg of
        ... ->
          -- Generate a game ID
          ( updatedModel
          , Random.generate GeneratedGameId BGF.idGenerator
          )

        GeneratedGameId gameId ->
          -- Use the generated game ID
-}
idGenerator : Random.Generator GameId
idGenerator =
  case Words.words of
    head :: tail ->
      Random.uniform head tail
      |> Random.list 2
      |> Random.map (\w -> String.join "-" w)
      |> Random.map GameId

    _ ->
      Random.constant (GameId "xxx")


-- Server connection


{-| A board game server.
-}
type Server =
  Server
    { start : String
    , mPort : Maybe Int
    }


{-| Create a `Server` that uses a websocket connection (not a secure
websocket connection). For example

    wsServer "bgf.pigsaw.org"

will allow us to make connections of the form `ws://bgf.pigsaw.org/...`.
-}
wsServer : String -> Server
wsServer domain =
  Server
    { start = "ws://" ++ domain
    , mPort = Nothing
    }


{-| Create a `Server` that uses a secure websocket connection.
A call of the form

    wssServer "bgf.pigsaw.org"

will allow us to make connections of the form `wss://bgf.pigsaw.org/...`.
-}
wssServer : String -> Server
wssServer domain =
  Server
    { start = "wss://" ++ domain
    , mPort = Nothing
    }


{-| Explicitly set the port of a server, if we don't want to connect to
the default port. The default port is 80 for insecure connections and
443 for secure connections.

    wsServer "localhost" |> withPort 8080    -- ws://localhost:8080
-}
withPort : Int -> Server -> Server
withPort portInt (Server server) =
  Server
    { start = server.start
    , mPort = Just portInt
    }



{-| The address of a game which we can connect to.
-}
type Address =
  Address
    { start : String
    , mPort : Maybe Int
    , gameId : GameId
    }


{-| Create the address of an actual game we can connect to.

    gid1 = gameId "voter-when"
    gid2 = gameId "poor-modern"

    wsServer "localhost"
    |> withPort 8080
    |> withGameId gid1    -- We can join ws://localhost:8080/g/voter-when
    |> withGameId gid2    -- Changes to  ws://localhost:8080/g/poor-modern
-}
withGameId : GameId -> Server -> Address
withGameId gId (Server server) =
  Address
    { start = server.start
    , mPort = server.mPort
    , gameId = gId
    }


{-| Turn an `Address` into a URL, expressed as a string.
This is useful for debugging, or otherwise seeing what's going on under
the hood.
-}
toUrlString : Address -> String
toUrlString (Address addr) =
  let
    portStr =
      case addr.mPort of
        Just p ->
          ":" ++ String.fromInt p
        Nothing ->
          ""
  in
  addr.start ++ portStr ++ "/g/" ++ (fromGameId addr.gameId)


-- Open, send close


{-| Open a connection to server, with a given game ID, via an Elm port.

    import BoardGameFramework as BGF

    port outgoing : Enc.Value -> Cmd msg

    server = BGF.wssServer "bgf.pigsaw.org"
    gameId = BGF.gameId "notice-handle"

    -- Open a connection to wss://bgf.pigsaw.org/g/notice-handle
    BGF.open outgoing server gameId
-}
open : (Enc.Value -> Cmd msg) -> Server -> GameId -> Cmd msg
open cmder server gId =
  let
    addr = server |> withGameId gId
    encode =
      Enc.object
        [ ("instruction", Enc.string "Open")
        , ("url", toUrlString addr |> Enc.string)
        ]
  in
  cmder encode


{-| Send a message to the other clients.

In this example we'll send a `Body` message to other clients, which
requires us defining a JSON encoder for it.

    import BoardGameFramework as BGF

    type alias Body =
      { id : BGF.ClientId
      , name : String
      }

    bodyEncoder : Body -> Enc.Value
    bodyEncoder body =
      Enc.object
      [ ("id" , Enc.string body.id)
      , ("name" , Enc.string body.name)
      ]

    port outgoing : Enc.Value -> Cmd msg

    body =
      { id = "123.456"
      , name = "Tango"
      }

    -- Send body to the other clients (and we'll get a receipt).
    BGF.send outgoing bodyEncoder body
-}
send : (Enc.Value -> Cmd msg) -> (a -> Enc.Value) -> a -> Cmd msg
send cmder enc body =
  let
    encode =
      Enc.object
        [ ("instruction", Enc.string "Send")
        , ("body", enc body )
        ]
  in
  cmder encode


{-| Close the connection to the game server.
Not strictly necessary in most cases,
because opening a new connection will automatically close an existing one.

    import BoardGameFramework as BGF

    port outgoing : Enc.Value -> Cmd msg

    -- Close our connection
    BGF.close outgoing
-}
close : (Enc.Value -> Cmd msg) -> Cmd msg
close cmder =
  let
    encode =
      Enc.object
        [ ("instruction", Enc.string "Close")
        ]
  in
  cmder encode


-- Receiving messages


{-| The unique ID of any client.
-}
type alias ClientId = String


{-| A message from the server, or the JavaScript connection layer.
It may contain a message specific to our application, which we say
is of type `a`.
See [the concepts document](https://github.com/niksilver/board-game-framework/blob/master/docs/concepts.md)
for many more details of envelopes.

The envelopes are:
* A welcome when our client joins;
* A receipt containing any message we sent;
* A message sent by another client peer;
* Notice of another client joining;
* Notice of another client leaving;
* Change of status with the server connection;
* An error reported by the JavaScript library.

The field names have consistent types and meaning:
* `me`: our client's own client ID.
* `others`: the IDs of all other clients currently in the game.
* `from`: the ID of the client (not us) who sent the message.
* `to`: the IDs of the clients to whom a message was sent, including us.
* `joiner`: the ID of a client who has just joined.
* `leaver`: the ID of a client who has just left.
* `num`: the ID of the envelope. After a Welcome envelope, nums will
  be consecutive.
* `time`: when the envelope was sent, in milliseconds since the epoch.
* `body`: the application-specific message sent by the client.
-}
type Envelope a =
  Welcome {me: ClientId, others: List ClientId, num: Int, time: Int}
  | Receipt {me: ClientId, others: List ClientId, num: Int, time: Int, body: a}
  | Peer {from: ClientId, to: List ClientId, num: Int, time: Int, body: a}
  | Joiner {joiner: ClientId, to: List ClientId, num: Int, time: Int}
  | Leaver {leaver: ClientId, to: List ClientId, num: Int, time: Int}
  | Connection Connectivity
  | Error String


{-| The current connectivity state, received when it changes.

`Connecting` can also be interpretted as "reconnecting", because
if the connection is lost then the underlying JavaScript will try to
reconnect.

`Disconnected` will only be received if the client explicitly
asks for the connection to be closed; otherwise if a disconnection
is detected the JavaScript will be trying to reconnect.

Both `Connecting` and `Disconnected` mean there isn't a server connection,
but `Disconnected` means that the underlying JavaScript isn't attempting to
change that.
-}
type Connectivity =
  Connected
  | Connecting
  | Disconnected


-- Singleton string list decoder.
-- Expect a singleton string list, and output the value
singletonStringDecoder : Dec.Decoder String
singletonStringDecoder =
  let
    singleDecoder list = case list of
      [elt] -> Dec.succeed elt
      _ -> Dec.fail "Didn't get string singleton"
  in
  Dec.list Dec.string
  |> Dec.andThen singleDecoder


{-| Decode an incoming envelope.
When an envelope is sent it is encoded as JSON, so it needs to be
decoded when it's received. Our framework
can handle most of that, but it needs help when the envelope contains
a message from a client peer (a body), because that's specific to our
application.

The body is said to be of some type `a`,
so we need to provide a JSON that produces an `a`.

If the decoding of the envelope is successful we will get an
`Ok (Envelope a)`. If there is a problem we will get an `Err Error`.

In this example we expect our envelope body to be a JSON object
containing an `id` field and a `name` field, both of which are strings.

    import Dict exposing (Dict)
    import Json.Decode as Dec
    import Json.Encode as Enc
    import BoardGameFramework as BGF

    -- Raw JSON envelopes come into this port
    port incoming : (Enc.Value -> msg) -> Sub msg

    type alias Body =
      { id : BGF.ClientId
      , name : String
      }

    type alias MyEnvelope = BGF.Envelope Body

    -- A JSON decoder which transforms our JSON object into a Body.
    bodyDecoder : Dec.Decoder Body
    bodyDecoder =
      Dec.map2
        Body
        (Dec.field "id" Dec.string)
        (Dec.field "name" Dec.string)

    type Msg =
      ...
      | Received (Result BGF.Error MyEnvelope)
      | ...

    -- Turn some envelope into a Msg which we can handle in our
    -- usual update function.
    receive : Enc.Value -> Msg
    receive v =
      BGF.decode bodyDecoder v
      |> Received

    -- We'll use this in our usual main function to subscribe to
    -- incoming envelopes and process them.
    subscriptions : Model -> Sub Msg
    subscriptions model =
      incoming receive

So after subscribing to what comes into our port, the sequence is:
an envelope gets decoded as a `Result BGF.Error MyEnvelope; this
gets wrapped into an application-specific `Received` type; we will
handle that in our usual `update` function.
-}
decode : Dec.Decoder a -> Enc.Value -> Result Dec.Error (Envelope a)
decode bodyDecoder v =
  let
    stringFieldDec field =
      Dec.field field Dec.string
      |> Dec.map (\val -> (field, val))
    intentDec = stringFieldDec "Intent"
    connectionDec = stringFieldDec "connection"
    errorDec = stringFieldDec "error"
    purposeDec = Dec.oneOf [intentDec, connectionDec, errorDec]
    purpose = Dec.decodeValue purposeDec v
  in
  case purpose of
    Ok ("Intent", "Welcome") ->
      let
        toRes = Dec.decodeValue (Dec.field "To" singletonStringDecoder) v
        fromRes = Dec.decodeValue (Dec.field "From" (Dec.list Dec.string)) v
        numRes = Dec.decodeValue (Dec.field "Num" Dec.int) v
        timeRes = Dec.decodeValue (Dec.field "Time" Dec.int) v
        make to from num time =
          Welcome
          { me = to
          , others = from
          , num = num
          , time = time
          }
      in
        Result.map4 make toRes fromRes numRes timeRes

    Ok ("Intent", "Peer") ->
      let
        fromRes = Dec.decodeValue (Dec.field "From" singletonStringDecoder) v
        toRes = Dec.decodeValue (Dec.field "To" (Dec.list Dec.string)) v
        numRes = Dec.decodeValue (Dec.field "Num" Dec.int) v
        timeRes = Dec.decodeValue (Dec.field "Time" Dec.int) v
        bodyRes = Dec.decodeValue (Dec.field "Body" bodyDecoder) v
        make to from num time body =
          Peer
          { from = from
          , to = to
          , num = num
          , time = time
          , body = body
          }
      in
        Result.map5 make toRes fromRes numRes timeRes bodyRes

    Ok ("Intent", "Receipt") ->
      let
        meRes = Dec.decodeValue (Dec.field "From" singletonStringDecoder) v
        othersRes = Dec.decodeValue (Dec.field "To" (Dec.list Dec.string)) v
        numRes = Dec.decodeValue (Dec.field "Num" Dec.int) v
        timeRes = Dec.decodeValue (Dec.field "Time" Dec.int) v
        bodyRes = Dec.decodeValue (Dec.field "Body" bodyDecoder) v
        make me others num time body =
          Receipt
          { me = me
          , others = others
          , num = num
          , time = time
          , body = body
          }
      in
        Result.map5 make meRes othersRes numRes timeRes bodyRes

    Ok ("Intent", "Joiner") ->
      let
        fromRes = Dec.decodeValue (Dec.field "From" singletonStringDecoder) v
        toRes = Dec.decodeValue (Dec.field "To" (Dec.list Dec.string)) v
        numRes = Dec.decodeValue (Dec.field "Num" Dec.int) v
        timeRes = Dec.decodeValue (Dec.field "Time" Dec.int) v
        make to from num time =
          Joiner
          { joiner = from
          , to = to
          , num = num
          , time = time
          }
      in
        Result.map4 make toRes fromRes numRes timeRes

    Ok ("Intent", "Leaver") ->
      let
        fromRes = Dec.decodeValue (Dec.field "From" singletonStringDecoder) v
        toRes = Dec.decodeValue (Dec.field "To" (Dec.list Dec.string)) v
        numRes = Dec.decodeValue (Dec.field "Num" Dec.int) v
        timeRes = Dec.decodeValue (Dec.field "Time" Dec.int) v
        make to from num time =
          Leaver
          { leaver = from
          , to = to
          , num = num
          , time = time
          }
      in
        Result.map4 make toRes fromRes numRes timeRes

    Ok ("connection", "connected") ->
      Ok (Connection Connected)

    Ok ("connection", "connecting") ->
      Ok (Connection Connecting)

    Ok ("connection", "disconnected") ->
      Ok (Connection Disconnected)

    Ok ("error", str) ->
      Ok (Error str)

    Ok (field, val) ->
      Dec.Failure ("Unrecognised " ++ field ++ " value: '" ++ val ++ "'") v
      |> Err

    Err jsonError ->
      Err jsonError


decoder : Dec.Decoder a -> Dec.Decoder (Envelope a)
decoder bodyDecoder =
  let
    stringFieldDec field =
      Dec.field field Dec.string
      |> Dec.map (\val -> (field, val))
    intentDec = stringFieldDec "Intent"
    connectionDec = stringFieldDec "connection"
    errorDec = stringFieldDec "error"
    purposeDec = Dec.oneOf [intentDec, connectionDec, errorDec]
  in
    purposeDec
    |> Dec.andThen (purposeHelpDec bodyDecoder)


purposeHelpDec : Dec.Decoder a -> (String, String) -> Dec.Decoder (Envelope a)
purposeHelpDec bodyDecoder purpose =
  case purpose of
    ("Intent", "Welcome") ->
      let
        toDec = Dec.field "To" singletonStringDecoder
        fromDec = Dec.field "From" (Dec.list Dec.string)
        numDec = Dec.field "Num" Dec.int
        timeDec = Dec.field "Time" Dec.int
        make to from num time =
          Welcome
          { me = to
          , others = from
          , num = num
          , time = time
          }
      in
      Dec.map4 make toDec fromDec numDec timeDec

    ("Intent", "Peer") ->
      let
        fromDec = Dec.field "From" singletonStringDecoder
        toDec = Dec.field "To" (Dec.list Dec.string)
        numDec = Dec.field "Num" Dec.int
        timeDec = Dec.field "Time" Dec.int
        bodyDec = Dec.field "Body" bodyDecoder
        make to from num time body =
          Peer
          { from = from
          , to = to
          , num = num
          , time = time
          , body = body
          }
      in
      Dec.map5 make toDec fromDec numDec timeDec bodyDec

    ("Intent", "Receipt") ->
      let
        meDec = Dec.field "From" singletonStringDecoder
        othersDec = Dec.field "To" (Dec.list Dec.string)
        numDec = Dec.field "Num" Dec.int
        timeDec = Dec.field "Time" Dec.int
        bodyDec = Dec.field "Body" bodyDecoder
        make me others num time body =
          Receipt
          { me = me
          , others = others
          , num = num
          , time = time
          , body = body
          }
      in
      Dec.map5 make meDec othersDec numDec timeDec bodyDec

    ("Intent", "Joiner") ->
      let
        fromDec = Dec.field "From" singletonStringDecoder
        toDec = Dec.field "To" (Dec.list Dec.string)
        numDec = Dec.field "Num" Dec.int
        timeDec = Dec.field "Time" Dec.int
        make to from num time =
          Joiner
          { joiner = from
          , to = to
          , num = num
          , time = time
          }
      in
      Dec.map4 make toDec fromDec numDec timeDec

    ("Intent", "Leaver") ->
      let
        fromDec = Dec.field "From" singletonStringDecoder
        toDec = Dec.field "To" (Dec.list Dec.string)
        numDec = Dec.field "Num" Dec.int
        timeDec = Dec.field "Time" Dec.int
        make to from num time =
          Leaver
          { leaver = from
          , to = to
          , num = num
          , time = time
          }
      in
      Dec.map4 make toDec fromDec numDec timeDec

    ("connection", "connected") ->
      Dec.succeed (Connection Connected)

    ("connection", "connecting") ->
      Dec.succeed (Connection Connecting)

    ("connection", "disconnected") ->
      Dec.succeed (Connection Disconnected)

    ("connection", value) ->
      Dec.fail <| "Unrecognised connection value: '" ++ value ++ "'"

    (field, value) ->
      Debug.todo "Not implemented!"
