REBOL []

; This object implements the server side of a request broker.
rugby-server: make hipe-serv
[
  http-srv: none
  compression: no
  ip-address: system/network/host-address
  
  ; Block containg words that are allowed to be executed.
  exec-env: copy []


  ; Block containing generated stub code.
  stubs: none

  build-proxy: func
  [
    name [word!]
    /secure-code
    /with hp [integer!]
    /local hu command f spec my-spec f-name meta-f p1 p2 li 
  ]
  [
    ;Don't make stubs on things that aren't functions
    if not any-function? get/any name 
    [ throw make error! rejoin ["Rugby error: trying to generate a proxy on a type that is not a function for " to-string name "has type: " type? get/any name]]

    hu: rejoin [ http:// rugby-server/ip-address ":" either with [hp][8002] ]

    command: either secure-code [{sexec}] [{rexec} ]

    ;Get the function and its specs
    f: get name
    spec: third :f
    my-spec: first :f
    f-name: mold name  

    ;The meta function.
    ;This is the actual code block that is returned upon invocation
    ;The generated defined function use a use context extension to 
    ;get access to itself.
    meta-f: copy/deep 
    [
      ;the function name
      (to-set-word f-name )
      ;Our use context to give acces to ourself
      func (meta-spec)
        [
          ;The rugby ports
          http-port: {_*http*_}

          ;The statement that rugby will send
          statement: copy []

          ;The rugby statement (rexec or sexec)
          rugby-statement: copy []

          ;By default we start with copying variables
          ref-mode: on      
          
          ;Our compose switched rugby command (sexec or rexec)
          rugby-comm: copy (command) 

          ;with /with
          append rugby-comm "/with"

          ;The name of the function to execute on the remote site
          comm: copy (f-name )

          ;my function signature
          ;my-spec: copy first :myself
          my-spec: copy (meta-spec)

          ;Strip the local varaiables
          if found? index: find my-spec /local
          [ my-spec: copy/part my-spec index]
          
          ;Some parsing here
          ;Composed in. For parse rules see below
          p1: [(p1)]
          p2: [(p2)]
          

          ;Parse my spec to find out how I am called
          parse my-spec [ any [ p1 | p2 | skip ]]
          
          ;create our complete function call with refinements
          ;An insert because the variables are already inserted 
          ;via the parsing
          insert head statement to-path comm
          ;Create our rugby statement
          insert rugby-statement to-path rugby-comm
          ;with as parameter statement (the remote function to call)
          append/only rugby-statement statement

          ;DO we use http or tcp transport?
          append rugby-statement http-port
          do bind rugby-statement 'do
        ]

    ]

    ;The two parse rules for meta-f.
    ;Due to the parens in parse rules and compose....
    ;p1 matches refinements and adds them to comm (the remote function)
    ;or rugby-comm (rexec or sexec)
    ;If a refinement is matched and active, ref-mode goes on so that variables 
    ;are copied in p2
    p1: [ set r refinement! 
          (either get bind to-word r 'comm 
            [ 
              either any [ r = /deferred r = /oneway]
              [
                append rugby-comm mold r
              ]
              [
                append comm mold r 
              ]
              ref-mode: on
            ]
            [ ref-mode: off ]
          )
        ]
    ;matches words and copies their values to the statement if ref-mode = on
    p2: [ set w word!
      (if ref-mode [ append/only statement get bind to-word w 'comm])]


    ;Get only the code to /local from the signature block
    if found? li: find spec /local
    [ spec: copy/part spec ((index? li) - 1) ]
    
    ;Generate the function signature
    ;do mold because of the type conservation
    meta-spec: do mold spec
    ;Append the extra stub refinements
    append meta-spec [ /deferred /oneway ]
    ;append some local variables
    append meta-spec [ /local http-port statement my-spec
      p1 p2 ref-mode comm r index what-ref rugby-statement
    rugby-comm]
    ;Compose does block flattening, hence an extra block.
    meta-spec: append/only copy [] meta-spec  

    return compose/deep meta-f
  ]

  build-stubs: func
  [
    {Builds stub code that allows remote invocation of exposed functions
     asif they were local to the client.}
    expose-list [block!] {List of functions to expose.}
    /secure-code
    /with hp [integer!] {Number of the http port.}
    /local stub num
  ]
  [
    stub: copy []

    ;build our stubs
    num: either with [hp] [8002]

    repeat entry expose-list
    [  
      either secure-code
      [ append stub build-proxy/with/secure-code to-word entry num ]
      [ append stub build-proxy/with to-word entry num]
    ];repeat
    return stub
  ]

  get-stubs: func []
  [
    return stubs
  ]

  extend-env: func [words [block!] code [string!]][
    do code
    append exec-env words 
    stubs: build-stubs/with exec-env http-port-num
    exec-env
  ]

  nargs: func 
  [
    {Returns the total number of args of a function (with and without
     refinements)}
    f [word! lit-path!]
    /local argc f-blk f-ref f-sig ref-pos next-ref-pos
  ]
  [
    ;The total number or arguments
    argc: 0
    ;We either have a path or a function
    ;If we have a path, we count the number
    ;of arguments of the supplied refinements first.
    either path? f
    [
      ;Translate the path to a block
      f-blk: to-block f 
      
      ;Is it a function?
      if not any-function? get/any first f-blk
      [throw make error! "Rugby error: invocation not on a function"]
      
      bind f-blk 'do
      ;The refinements used
      f-ref: next head f-blk
      ;the function signature
      f-sig: first get first f-blk
      ;Now get the number of arguments foreach refinement
      ;and add them to argc
      repeat ref f-ref
      [
        ;Find the ref refinement
        ref-pos: find/tail f-sig to-refinement ref
        ;If succeed in the find
        if not none? ref-pos
        [
          ;try to find the next one
          next-ref-pos: find ref-pos refinement!
          if not none? next-ref-pos
          [
            argc: argc + ((index? next-ref-pos) - (index? ref-pos))
          ];if not none next-ref-pos
        ];if not none? ref-pos
      ];foreach ref f-ref
      
    ];either path? f first clause
    [
      if not any-function? get/any f
      [ throw make error! "Rugby error: invocation not on a function" ]
      f-sig: first get f
    ];either path? f second clause

    ;Add the number of function arguments
    argc: argc + -1 + index? any [ find f-sig refinement! tail f-sig ]  
    
  ];nargs


  compose-msg: func
  [
    {Creates a message for on the wire transmission.}
    msg [any-block!]
  ]
  [
    f-msg: reduce [checksum/secure mold do mold msg msg]
    return either self/compression
    [ mold compress mold f-msg ]
    [ mold f-msg ]
  ]

  clear-buffer: func 
  [ 
    cleary [port!] 
    /upto {clear a specified amount of bytes}
      n {the number of bytes to be cleared}
    /local msg size-read
  ]
  [
    msg: copy {}
    loop either upto [ n ][ 1 ]
    [
      until
      [
        size-read: read-io cleary msg 1
        1 = size-read
      ]
    ]
  ]

  decompose-msg: func
  [
    {Extracts a message that has been transmitted on the wire.}
    msg [any-string!]
    /local im1 im2 
  ]
  [
    
    either self/compression
    [
      im1: trim/all msg
;      either all [ #"#" = first msg #"{" = second msg  #"}" = last msg ]
      either parse to-block msg [ set im1 binary! ]
;      [ im2: decompress do im1]
      [im2: decompress im1 ]
      [ make error! {Invalid message format.} ]
    ]
    [
      im2: to-block msg
      type? first im2
    ]
  

;    either all [ #"[" = first im2 #"]" = last im2]
    either parse to-block im2 [ set im1 block! ]
;    [return do im2]
    [ return im1 ]
    [ make error! {Invalid message format}]
  ]

  check-msg: func
  [
    {Check message integrity.}
    msg [any-block!]
  ]
  [
    return (checksum/secure mold second msg) = first msg
  ]

  write-msg: func
  [
   {Does a low-level write of a message.}
    msg
    dest [port!]
    /local length
  ]
  [
    ; We try to write at least 16000 bytes at a time
    either 16000 > length? msg
    [
      length: write-io dest msg length? msg

      ; Message written, we're done
      either length = length? msg
      [
        return true
      ]
      ; We're not done. Return what we have written
      [
        return length
      ]
    ]; either 16000 > first clause
    [
      length: write-io dest msg 16000
    ]
    ; We're done, port is closed
    if 0 > length [ return true]

    return length
  ]

  safe-exec: func
  [
    {Safely executes a message. Checks the exec-env variable for a list of
     valid commands to execute.}
    statement [any-block!]
    env [any-block!]
    /local n stm act-args stm-blok
  ]
  [
    if found? find env either path? statement/1 [statement/1/1][statement/1]
    [
      n: nargs to-lit-path statement/1
      act-args: n

      stm-blok: copy statement
      until
      [
        stm-blok: find/tail stm-blok [make object!]
        act-args: act-args + 2
        not found? stm-blok
      ]
      
      stm: copy/part statement act-args
      return do stm
    ]
    make error! rejoin [ "Rugby server error: Unsupported function: "
        mold statement ]
  ]

  send-header: func
  [
    {Send a http OK header}
    client-port
  ]
  [
    insert client-port {HTTP/1.0 200 OK^/Content-type:  text/plain ^/^/}
  ]

  request-read?: func
  [
    {Checks to see whether a HTTP request has been read}
    req [string!] {The request to be analyzed}
  ]
  [
    return found? find req "xtra-info:"
  ]
  
  web-clearies: func
  [
    req [string!]
    /local r r1 t1
  ]
  [  
    return (length? " 1234567891011121314") -
      (length? find/tail req "xtra-info:")
  ]

  suspend: func [] [
    ;We have to make sure hipe isn't sending events to the port/handler
    ;anymore!
    port-q-delete current-port
    object-q-delete current-port
    throw 'suspend
  ]

  resume: func [ 
    value  
    port [port!]
    ][
    write-result value port
    return
  ]
  
  get-request: func
  [
    {Extracts a Rugby request from a HTTP request.}
    req [string!] {The request to extract}
    /local rule rugby-req
  ]
  [
    rule: [ thru "rugby-rq: " thru "[***" copy rugby-req to "***]" ]
    parse req rule
    return rugby-req
  ]

  ;Our web server handler
  web-handler: func
  [
    o [object!]
    /local ud data-read the-request result wr-res
  ]
  [
    catch
    [
      ;This is the first time we enter for this object!
      ;Initialize the user data
      if none? o/user-data
      [
        o/user-data: make object!
        [
          request-read: false
          request-data: copy {}
          result-data: copy {}
          result: copy {}
          header-written: false
          result-written: false
        ]
      ]

      ;Just a short-hand
      ud: o/user-data

      ;We still have data to read
      if not ud/request-read
      [
        data-read: copy/part o/port 16
        append ud/request-data data-read
        ud/request-read: request-read? ud/request-data
        return
      ]

      ;We have our data, but did not do a rexec yet.
      if (empty? ud/result)
      [
        if error? try [ the-request: decompose-msg get-request ud/request-data ]
        [ 
          stop o/port 
          return
        ]

        either check-msg the-request 
        [
          if error? set/any 'result try
            [ safe-exec bind pick the-request 2 'do exec-env]
          [
            result:  disarm result
          ]

          ;Do we have a return value at all?
          either value? 'result
          [
            ud/result: compose-msg append/only copy [] get/any 'result
          ]       
          [  
            ud/result: compose-msg copy [unset!]
          ]

          insert ud/result copy {[***}
          append ud/result copy {***]}
        ]
        [
          ;We can't do a rexec, hence we do not proxy. Kill'em all (might be
          ; a malicious hacker!)
          ;clear-buffer o/port
          stop o/port
          return
        ]
      ]; if empty? ud/result 

      ;Write the header
      if not ud/header-written
      [
        send-header o/port
        ud/header-written: true
        return
      ]

      ;Is the result returned?
      if not ud/result-written
      [
        wr-res: write-msg ud/result o/port
        either logic? wr-res
        [
          ud/result-written: true
          clear-buffer/upto o/port web-clearies ud/request-data
          stop o/port
        ]
        [
          remove/part ud/result wr-res
        ]; either
        return
      ]
    ] 'suspend 
    attempt [ 
      clear-buffer/upto o/port web-clearies ud/request-data
    ]
     
  ];web-handler

  write-result: func [
    value
    port [port!]
    /local message wr-res
  ][
    if error? value [ value: disarm value]
    message: compose-msg append/only copy [] value
    insert message copy {[***}
    append message copy {***]}
    send-header port
    wr-res: write-msg message port
    while [not logic? wr-res][
      remove/part message wr-res
      wr-res: write-msg message port
    ]
    stop port
    return
  ]
   
  http-port-num: 8002

  init-rugby: func
  [
    {Inits our server according to our server port-spec and with rugby's
     do-handler}
    x-env [any-block!]    
    http-num [integer!]
  ]
  [
    rugby-server/http-srv: http-num
    
    append exec-env x-env
    http-port-num: http-num
    ; Build the stubs and store them in our object variable.
    stubs: copy build-stubs/with exec-env http-num
  ]

  init-http-proxy: func
  [
    {Inits our http proxy}
    port-spec [port!]
  ]
  [
    init-server-port port-spec :web-handler
  ]

]

set 'get-stubs get in rugby-server 'get-stubs
set 'suspend get in rugby-server 'suspend
set 'resume get in rugby-server 'resume
set 'extend-env get in rugby-server 'extend-env

serve: func
[
  {Exposes a set of commands as a remote service}
  commands  [block!] {The commands to expose}
  /with {Expose on a different port than tcp://:8002}
    p [url!] {Other port}
  /restrict {Restrict access to a block of ip numbers}
    r [block!] {ip numbers}
  /nostubs {Don't provide access to stubs with get-stubs function.}
  /local local-commands http-dest
]
[
  local-commands: copy commands

  ; We only add a function to get at the stubs if we are asked to.
  if not nostubs
  [
    append local-commands [ get-stubs extend-env ]
  ]
  
  ;Do we have restrictions active?
  if restrict [ rugby-server/restrict-to r ]

  ;On what port do we do the http proxy
  http-dest: make port! either with [ p ][ tcp://:8002 ]
  rugby-server/init-http-proxy http-dest
  
  rugby-server/init-rugby local-commands http-dest/port-id
  rugby-server/serve
]
