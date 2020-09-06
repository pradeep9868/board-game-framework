-- Copyright 2020 Nik Silver
--
-- Licensed under the GPL v3.0. See file LICENCE.txt for details.


module BoardGameFramework.Wrap exposing
  ( encode, decoder
  )


import Json.Encode as Enc
import Json.Decode as Dec


encode : String -> Enc.Value -> Enc.Value
encode name enc =
  Enc.object
  [ (name, enc)
  ]


decoder : String -> Dec.Decoder a -> Dec.Decoder a
decoder name dec =
  Dec.field name dec
