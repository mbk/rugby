REBOL []
;*** TOUCHDOWN SERVER ***

touchdown-server: make object!
[
  key: none
  secure-stubs: none
  
  init-key: does
  [
    if not key
    [
      if any [ not exists? %tdserv.key
           error? try [ key: do read %tdserv.key ] ]
      [
        ; We either don't have the key file, or there was an error
        ; reading it. Let's generate a new one.
        key: rsa-make-key key
        rsa-generate-key key 1024 3
        error? try [write %tdserv.key mold key ]
      ]
    ]
  ]

  get-public-key: does [ return key/n]

  get-session-key: func [ s-key [binary!] /local k]
  [
    k: rsa-encrypt/decrypt/private key s-key
    return k
  ]

  decrypt: func
  [
    msg [binary!]
    k [binary!]
    /local res dec-port crypt-str
  ]
  [
    crypt-str: 8 * length? k
    dec-port: open make port!
    [
      scheme: 'crypt
      algorithm: 'rijndael
      direction: 'decrypt
      strength: crypt-str
      key: k
      padding: true
    ]
    insert dec-port msg
    update dec-port
    res: copy dec-port
    close dec-port
    return to-string res
  ]

  encrypt: func
  [
    msg [binary! string!]
    k [binary!]
    /local res enc-port crypt-str
  ]
  [
    crypt-str: 8 * length? k
    enc-port: open make port!
    [
      scheme: 'crypt
      algorithm: 'rijndael
      direction: 'encrypt
      strength: crypt-str
      key: k
      padding: true
    ]
    insert enc-port msg
    update enc-port
    res: copy enc-port
    close enc-port
    return res
  ]


  get-message: func
  [
    msg [binary!]
    dec-key [binary!]
  ]
  [
    decrypt msg dec-key
  ]

  get-return-message: func
  [
    enc-key [binary!]
    /with
      r
    /local blok msg
  ]
  [
    blok: copy []
    ;Insert only if we have a value
    if with
    [
      append/only blok r
    ]
    msg: encrypt mold blok enc-key
    return msg
  ]

  sexec-srv: func
  [
    stm [block!]
    /local stm-blk ret
  ]
  [
    stm-blk: first load/all get-message load/all stm/2
      get-session-key load/all stm/1

    set/any 'ret rugby-server/safe-exec stm-blk rugby-server/exec-env

    either value? 'ret
    [ return get-return-message/with get-session-key do stm/1 ret]
    [ return get-return-message get-session-key do stm/1 ]
  ]

];touchdown-server

negotiate: does
[
  return append append copy [] crypt-strength? touchdown-server/get-public-key
]

get-secure-stubs: does
[
  return touchdown-server/secure-stubs
]

set 'sexec-srv get in touchdown-server 'sexec-srv

secure-serve: func
[
  {Start a secure server.}
  statements [block!]
  /with {On a specific port}
    p [url!] {The port spec.}
  /restrict {Limit access to specific IP addresses}
    rs [block!] {Block of allowed IP addresses}
  /nostubs {Don't provide access to stubs with get-secure-stubs function.}
  /local s-stm dest
]
[
  touchdown-server/init-key

  ; Block containing generated secure stub code
  s-stm: append copy statements [ negotiate sexec-srv ]

  ; Build the secure version of the stubs.
  dest: either with [ p ][ tcp://:8002 ] 

  ;Build our function call
  if not nostubs
  [
    append s-stm [ get-secure-stubs ]
    touchdown-server/secure-stubs:
      rugby-server/build-stubs/secure-code/with s-stm
    to-integer find/tail/last dest ":"
    ; And add a function to access them.
  ]

  ; Call serve with the right refinements.
  either nostubs
  [
    either restrict 
    [ serve/nostubs/restrict/with s-stm rs dest]
    [ serve/nostubs/with s-stm dest]
  ]
  [
    either restrict 
    [ serve/with/restrict s-stm dest rs ]
    [ serve/with s-stm dest]
  ]
]
