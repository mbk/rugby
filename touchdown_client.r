REBOL []

;*** TOUCHDOWN CLIENT ***


touchdown-client: make object!
[

  key-cache: copy []
  deferred-keys: copy []
  http-deferred-keys: copy []
  
  decrypt: func
  [
    {Generic decryption function}
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

  negotiate: func 
  [
    {Negotiates a session strengh and public rsa keyi with a touchdown
     server.}
    dest [url!]
    /local serv-strength
  ]
  [
    if not found? find key-cache mold dest
    [
      serv-strength: rexec/with [negotiate] dest
      
      if not none? serv-strength
      [
        append key-cache mold dest
        append/only key-cache serv-strength
      ]
      return serv-strength
    ]
    return select key-cache mold dest
  ]

  generate-session-key: func
  [
    {Idem.}
    crypt-str [integer!]
  ]
  [
    return copy/part checksum/secure mold now 16
  ]

  secure-result-available?: func
  [
    {Is a deferred http result available}
    index [integer!]
  ]
  [
    result-available? index
  ]

  get-secure-result: func
  [
    {Returns a deferred and secured http request}
    index [integer!]
    /local s-key res ret
  ]
  [
    s-key: select http-deferred-keys index
    if none? s-key
    [
      make error! join {Rugby error: No session key to match}
        { the deferred http request}
    ]
    res: get-http-result index

    if object? res [ return remake-error res ]
    
    ;Cleanup or key list
    remove remove find http-deferred-keys index
    set/any 'ret pick get-return-message res s-key 1

    either object? get/any 'ret
    [
      return rugby-client/remake-error ret
    ]
    [
      return get/any 'ret
    ]
  ]  
 
  wait-for-secure-result: func
  [
    {Waits for a secured result}
    index [integer!]
  ]
  [
    until [secure-http-result-available? index ]
    get-secure-http-result index
  ]
        
  generate-message: func
  [
    stm [block!]
    s-key [binary!]
    r-key [object!]
    /local blk-stm p-blk
  ]
  [
    blk-stm: copy [ sexec-srv ]
    p-blk: copy []

    append p-blk rsa-encrypt r-key s-key
    append p-blk encrypt mold stm s-key
    append/only blk-stm p-blk
    return blk-stm
  ]

  get-return-message: func
  [
    stm
    s-key [binary!]
    /local ret
  ]
  [
    set/any 'ret do  decrypt stm s-key
    return get/any 'ret
  ]

  sexec: func 
  [
    {A secure exec facility a la rexec for /Pro and /COmmand users}
    stm [any-block!]
    /with
      dest [url!]
    /deferred
    /local port sst crypt-str s-key ps-key r-key g-stm def-index
  ]
  [
    port: either with [ dest] [http://localhost:8002]

    sst: negotiate port
      
    if none? sst [print "no sst" return none]

    either (crypt-strength? = 'full)
    [
      either (first sst) = 'full
      [
        crypt-str: 128
      ]
      [
        crypt-str: 56
      ]
      ]
    [
      crypt-str: 56
    ]

    ;generate our session-key
    s-key: generate-session-key crypt-str

    ;get and initialize an rsa-key from the server's public key (second sst)
    ps-key: second sst
    r-key: rsa-make-key
    r-key/n: ps-key
    r-key/e: 3

    ;generate our sexec message
    g-stm: generate-message stm s-key r-key
      
    either not deferred
    [
      ;A heavy one: get the first element of the decrypted return message
      ;of you request over http
      do get-return-message rexec/with g-stm port s-key 
    ]
    [
      ;What's our http-index
      def-index: rexec/with/deferred g-stm port s-key 1
      repend http-deferred-keys [def-index s-key]
      return def-index
    ]
  ];sexec

];touchdown-client


set 'sexec get in touchdown-client 'sexec
set 'secure-result-available? get in touchdown-client 'secure-result-available?
set 'wait-for-secure-result get in touchdown-client 'wait-for-secure-result
set 'get-secure-result get in touchdown-client 'get-secure-result
