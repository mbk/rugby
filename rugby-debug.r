REBOL [
    Title: "Rugby"
    File: %rugby-debug.r
]

current-port: none

hipe-serv: make object!
[
  server-ports: copy []
  server-map: copy []
  port-q: copy []
  object-q: copy []
  threads: copy []
  current-thread: none
  conn-timeout: 0:0:30

  max-thread-waiting: 0

  add-thread: func [o [object!] {The thread to add}]
  [
    append hipe-serv/threads o
    o
  ]

  remove-thread: func [o [object!] {The thread to remove}]
  [
    remove find head hipe-serv/threads o
  ]

  process-thread: func [/local do-thread]
  [
    do-thread: none
    if empty? hipe-serv/threads 
    [ return ]
    if none? current-thread [ current-thread: head hipe-serv/threads]
    if tail? current-thread [current-thread: head current-thread]
    do-thread: pick current-thread 1

    if object? do-thread 
    [
      either 'clean-up = do-thread/code-pointer
      [
        error? try [ do do-thread/clean-up ]
        remove-thread do-thread
      ] 
      [
        if error? try [ do get/any in do-thread do-thread/code-pointer]
        [ 
          if found? find first do-thread 'clean-up
          [ 
            ;do additional cleanup
            error? try 
            [
              do do-thread/clean-up 
            ]
          ]
          remove-thread do-thread
        ]
      ]
    ]
    
    if not tail? current-thread [ current-thread: next current-thread]
    
  ]

  get-handler: func
  [
    {Returns the handler for a given server port}
    p [port!]
  ]
  [
    return select server-map p
  ]

  add-server-port: func
  [
    {Adds a server port and its handler to the list and the map}
    p [port!]
    handler [any-function!]
  ]
  [
    append server-ports p
    append server-map p
    append server-map :handler
    return
  ]

  remove-server-port: func
  [
    {Removes a server from our list and map}
  ]
  [
    remove find server-ports p
    remove remove find server-map p
    return
  ]

  port-q-delete: func
  [
    {Removes a port from our port list.}
    target [port!]
  ]
  [
    remove find port-q target
  ]

  port-q-insert: func
  [
    {Inserts a port into our port list.}
    target [port!]
  ]
  [
    append port-q target
  ]

  object-q-insert: func
  [
    {Inserts a port and its corresponding object into the object queue.}
    serv [port!] {The server port}
    target [port!] {The connection}
    /local o my-handler
  ]
  [
    my-handler: get-handler serv
    append hipe-serv/object-q target
    o: make object!  [port: target handler: :my-handler user-data: none
    lastaccess: now]
    append hipe-serv/object-q o
  ]

  object-q-delete: func
  [
    {Removes a port and its corresponding object from the object queue.}
    target [port!]
  ]
  [
    remove/part find hipe-serv/object-q target 2
  ]

  start: func
  [
    {Initializes everything for a client connection on application level.}
    serv [port!] {The server port}
    conn [port!] {The connection port}
  ]
  [
    port-q-insert conn
    object-q-insert serv conn
  ]


  stop: func
  [
    {Cleans up after a client connection.}
    conn [port!]
    /local conn-object
  ]
  [
    port-q-delete conn
    error? try
    [
      conn-object: select hipe-serv/object-q conn
      close conn-object/port
      object-q-delete conn
    ]
  ]

  init-server-port: func
  [
    {Initializes our main server port.}
    p [port! url!]
    conn-handler [any-function!]
    /local dest
  ]
  [
    
    either url? p
    [ dest: make port! p]
    [ dest: p]
    
    add-server-port dest :conn-handler
    append port-q dest

    ; Increase the backlog for this server. 15 should be possible (default
    ; is 5)
    ;REMOVE this for compatibility (o.a. Mac) or set it to 5 or so.
    p/backlog: 15
    open/no-wait dest
  ]

  process-ports: func
  [
    {Processes all ports that have events.}
    portz [block!] {The port list}
    /local temp-obj
  ]
  [
    repeat item portz
    [
      current-port: item
      either (found? find server-ports item)      
      [
        either item/scheme = 'udp
        ;udp, so call our handler
        [ 
          temp-obj: get-handler item
          temp-obj copy item
        ]
        [ 
	        start item first item
        ]
      ]
      [
        if item/scheme = 'tcp
        [
          temp-obj: select hipe-serv/object-q item
          temp-obj/lastaccess: now
          temp-obj/handler temp-obj
          
        ]
      ]
    ]
  ]

  serve: func
  [
    {Starts serving. Does a blocking wait until there are events.
     Processes thread in the background as well!}
    /local portz
  ]
  [
    forever
    [
      portz: wait/all join port-q 0.005 ; <--- problem caused probably by the timeout
      either none? portz
      [ process-thread ]
      [
        process-ports portz
        ;If there are more than 100 threads, start processing anyway
        if hipe-serv/max-thread-waiting < length? hipe-serv/threads
        [ process-thread ]
      ]
      
    ]
  ]
]

set 'add-thread get in hipe-serv 'add-thread
set 'remove-thread get in hipe-serv 'remove-thread

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
    [ throw make error! "Rugby error: trying to generate a proxy on a type that is not a function" ]

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
          http-port: {_*http*_}
          statement: copy []
          rugby-statement: copy []
          ref-mode: on      
          rugby-comm: copy (command) 
          append rugby-comm "/with"
          comm: copy (f-name)
          my-spec: copy (meta-spec)
          if found? index: find my-spec /local
          [my-spec: copy/part my-spec index]
          p1: [(p1)]
          p2: [(p2)]
          parse my-spec [ any [ p1 | p2 | skip ]]
          insert head statement to-path comm
          insert rugby-statement to-path rugby-comm
          append/only rugby-statement statement
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
    ;HMK: Changed to allow lit-words to be copied in verbatim, but
    ;I'm not sure this fix covers everything.
    p2: [set w word!
      (if ref-mode [
        w: get bind to-word w 'comm
        append/only statement either any-word? :w [to lit-word! :w][:w]
      ])
    ]
    ;this is buggy for lit-word!
    ;p2: [set w word!
    ;  (if ref-mode [append/only statement get bind to-word w 'comm])]


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
    [ mold/all f-msg ] ; using mold/all here does not halt execution!
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
        ;1 = size-read ; HMK: Size-read is sometimes 0, which hangs this line
        1 >= size-read ; HMK
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
    ;HMK: changed to reflect correctly what happens in compose-msg
    return (checksum/secure mold do mold second msg) = first msg
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
    find/last req "xtra-info:"
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
  ]
  [
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
    cl offset ; HMK
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
          request-length: 0 ; HMK
          content-length: 0 ; HMK
          content-remaining: 0 ; HMK
          result: copy {}
          header-written: false
          result-written: false
        ]
      ]

      ;Just a short-hand
      ud: o/user-data

      ;We still have data to read
      unless ud/request-read
      [
	    
        until [
          insert tail ud/request-data copy/part o/port 16
          ud/content-length: find/last/tail ud/request-data "Content-Length: "
        ]
        ud/content-length:
          to integer! head clear find copy/part ud/content-length 10 newline
        ud/request-length: 2048 ; max copy length allowed
     probe   ud/content-remaining: max 0 ud/content-length
       probe head insert tail ud/request-data copy/part o/port ud/content-length + 10
        ud/request-read: true
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
          ud/result: compose-msg either value? 'result
          [
            append/only copy [] get/any 'result
          ]       
          [  
            copy [unset!]
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
    append local-commands [ get-stubs ]
  ]

  ;On what port do we do the http proxy
  http-dest: make port! either with [ p ][ tcp://:8002 ]
  rugby-server/init-http-proxy http-dest

  rugby-server/init-rugby local-commands http-dest/port-id
  rugby-server/serve
]


tunnel-ctx: context
[
  default-proxy: http://localhost:8002
  default-deferred-proxy: httpr://localhost:8002

  deferred-index: 0
  deferred-ports: copy []
  ret-vals: copy []
  compression: no

  transform-url: func
  [
    {Transforms a http url in a httpr url}
    u [url!]
    /local mark mu
  ]
  [
    replace copy u 'http 'httpr
  ]

  result?: func 
  [ 
    {Checks to see whether a string is a result}
    s [string! none!]
    /local val
  ]
  [
    if none? s [make error! {Rugby error: no result available for this index}]
    val: none
    parse/all s [ thru {[***} copy val to {***]} ]
    either none? val  [ return false] [return true]
  ]

  wait-for-result: func 
  [
    {waits for a http result}
    index [integer!]
  ]
  [
    until
    [
      wait 0.003 ; bug fix for potential hang. see also wait-for-secure-result
      ; a wait on the client. Could we do some timeout stuff here?
      result-available? index
    ]
    return get-result index
  ]

  append-port: func
  [
    {Appends a port to the deferred-ports list}
    p [port!]    
    /local res
  ]
  [
    res: copy {}
    deferred-index: 1 + deferred-index
    repend deferred-ports [ deferred-index p]
    repend ret-vals [deferred-index res]
    return deferred-index
  ]
  
  to-result: func 
  [
    {Return a result from a http request}
    ret-val [string!]
    /local res ret
  ]
  [  
    ;extract the result string
    parse/all ret-val [ thru {[***} copy res to {***]} ]
    ret: second decompose-msg res
    do ret
  ]

  compose-msg: func
  [
    {Creates a message for on the wire transmission.}
    msg [any-block!]
  ]
  [
    f-msg: reduce [checksum/secure mold do mold msg msg]
    return either self/compression 
    [ mold compress mold f-msg]
    [ mold/all f-msg]
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
      either all [ #"#" = first msg #"{" = second msg  #"}" = last msg ]
      [ im2: decompress do im1]
      [ make error! {Invalid message format.} ]
    ]
    [
      im2: msg
    ]

    either all [ #"[" = first im2 #"]" = last im2]
    [ return do im2 ]
    [ make error! {Invalid message format}]
  ]

  check-msg: func
  [
    {Check message integrity.}
    msg [any-block!]
  ]
  [
    ;HMK: changed to reflect correctly what happens in compose-msg
    return (checksum/secure mold do mold second msg) = first msg
  ]

  ;Not used anymore, doesn't work with suspend/resume (but why?)
  tunnel: func
  [
    {Tunnels a command using http as a transport layer}
    command [block!]
    /via
      v [url!]    
    /local cmd-block cmd-string proxy
  ]
  [
    proxy: either via [ v ][ default-proxy ]

    cmd-block: compose-msg command 
    cmd-string: rejoin [ {rugby-rq: [***} cmd-block
      {***] xtra-info: "1234567891011121314} ]
    return to-result read/custom proxy reduce [ 'post cmd-string ]
  ]

  remove-request: func [
    {Removes a request and closes the port}
    index [integer!] 
  ]
  [
    close select deferred-ports index
    remove remove find ret-vals index
    remove remove find deferred-ports index
    return
  ]

  get-result: func 
  [
    {returns the result of a deferred http request}
    index [integer!]
    /local res
  ]
  [
    result-available? index
    if result? select ret-vals index 
    [    
      res: select ret-vals index
      close select deferred-ports index
      remove remove find ret-vals index
      remove remove find deferred-ports index
      return to-result res      
    ]
    make error! {Rugby error: result not available}
  ]

  result-available?: func
  [
    {returns whether or not the result of a deferred http request is available}
    index [integer!]
    /local port ret temp-read
  ]
  [
    port: select deferred-ports index
    ret: select ret-vals index
    if any [ none? port none? ret]
    [make error! {Rugby error: No such port or return value}]
    
    temp-read: copy port
    if string? temp-read
    [
      append ret temp-read
      change next find ret-vals index ret
    ]
    return result? ret
  ]
  
  tunnel-deferred: func
  [
    {Tunnels a command using http as a transport layer}
    command [block!]
    /via
      v [url!]    
    /local cmd-block cmd-string proxy port-spec
  ]
  [
    proxy: either via [ v ][ default-proxy ]

    cmd-block: compose-msg command 
    cmd-string: rejoin [ {rugby-rq: [***} cmd-block
      {***] xtra-info: "1234567891011121314} ]
    port-spec: open/custom/direct/no-wait proxy reduce [ 'post cmd-string ]
    set-modes port-spec/sub-port [no-wait: true]
    return append-port port-spec    
  ]

  rexec: func
  [
    {Does a high-level rexec.}
    msg [any-block!]
    /with
      p [port! url!]
    /deferred
  ]
  [
    ;If we do http... tunnel it and return the result
    if deferred
    [
      ;Different than the default of tcp://locahost:8002 for the http proxy?
      return tunnel-deferred/via msg either with
        [ transform-url p ]
        [ httpr://localhost:8002 ]
    ];if http
    
    ;If we do http... tunnel it and return the result
    ;Different than the default of tcp://locahost:8002 for the http proxy?
    return wait-for-result tunnel-deferred/via msg either with [
      transform-url p][
      httpr://localhost:8002 ]
  ]
]

set 'result-available? get in tunnel-ctx 'result-available?
set 'get-result get in tunnel-ctx 'get-result
set 'wait-for-result get in tunnel-ctx 'wait-for-result
set 'rexec get in tunnel-ctx 'rexec
set 'remove-request get in tunnel-ctx 'remove-request

ctx-httpr: make object! [
    port-flags: 0
    open-check: none
    close-check: none
    write-check: none
    init: func [
        "Parse URL and/or check the port spec object" 
        port "Unopened port spec" 
        spec {Argument passed to open or make (a URL or port-spec)} 
        /local scheme
    ][
        if url? spec [net-utils/url-parser/parse-url port spec] 
        scheme: port/scheme 
        port/url: spec 
        if none? port/host [
            net-error reform ["No network server for" scheme "is specified"]
        ] 
        if none? port/port-id [
            net-error reform ["No port address for" scheme "is specified"]
        ]
    ]
    open-proto: func [
        {Open the socket connection and confirm server response.} 
        port "Initalized port spec" 
        /sub-protocol subproto 
        /secure 
        /generic 
        /locals sub-port data in-bypass find-bypass bp
    ][
        if not sub-protocol [subproto: 'tcp] 
        net-utils/net-log reduce ["Opening" to-string subproto "for" to-string port/scheme] 
        if not system/options/quiet [print ["connecting to:" port/host]] 
        find-bypass: func [host bypass /local x] [
            if found? host [
                foreach item bypass [
                    if any [
                        all [x: find/match/any host item tail? x]
                    ] [return true]
                ]
            ] 
            false
        ] 
        in-bypass: func [host bypass /local item x] [
            if any [none? bypass empty? bypass] [return false] 
            if not tuple? load host [host: form system/words/read join dns:// host] 
            either find-bypass host bypass [
                true
            ] [
                host: system/words/read join dns:// host 
                find-bypass host bypass
            ]
        ] 
        either all [
            port/proxy/host 
            bp: not in-bypass port/host port/proxy/bypass 
            find [socks4 socks5 socks] port/proxy/type
        ] [
            port/sub-port: net-utils/connect-proxy/sub-protocol port 'connect subproto
        ] [
            sub-port: system/words/open/lines compose [
                scheme: (to-lit-word subproto) 
                host: either all [port/proxy/type = 'generic generic bp] [port/proxy/host] [port/proxy/host: none port/host] 
                user: port/user 
                pass: port/pass 
                port-id: either all [port/proxy/type = 'generic generic bp] [port/proxy/port-id] [port/port-id]
            ] 
            port/sub-port: sub-port
        ] 
        if all [secure find [ssl tls] subproto] [system/words/set-modes port/sub-port [secure: true]] 
        port/sub-port/timeout: port/timeout 
        port/sub-port/user: port/user 
        port/sub-port/pass: port/pass 
        port/sub-port/path: port/path 
        port/sub-port/target: port/target 
        net-utils/confirm/multiline port/sub-port open-check 
        port/state/flags: port/state/flags or port-flags
    ]
    open: func [
        port "the port to open" 
        /local http-packet http-command response-actions success error response-line 
        target headers http-version post-data result generic-proxy? sub-protocol 
        build-port send-and-check create-request cookie-list][
        port/locals: make object! [list: copy [] headers: none] 
        generic-proxy?: all [port/proxy/type = 'generic not none? port/proxy/host] 
        build-port: func [] [
            sub-protocol: either port/scheme = 'https ['ssl] ['tcp] 
            open-proto/sub-protocol/generic port sub-protocol 
            ;port/url: rejoin [lowercase to-string port/scheme "://" port/host either port/port-id <> 80 [join #":" port/port-id] [copy ""] slash] 
            ;We need to change port/scheme to http to fool the world (httpr is no protocol in real life)
            port/url: rejoin [lowercase to-string 'http "://" port/host either port/port-id <> 80 [join #":" port/port-id] [copy ""] slash] 
            if found? port/path [append port/url port/path] 
            if found? port/target [append port/url port/target] 
            if sub-protocol = 'ssl [
                if generic-proxy? [
                    HTTP-Get-Header: make object! [
                        Host: join port/host any [all [port/port-id (port/port-id <> 80) join #":" port/port-id] #]
                    ] 
                    user: get in port/proxy 'user 
                    pass: get in port/proxy 'pass 
                    if string? :user [
                        HTTP-Get-Header: make HTTP-Get-Header [
                            Proxy-Authorization: join "Basic " enbase join user [#":" pass]
                        ]
                    ] 
                    http-packet: reform ["CONNECT" HTTP-Get-Header/Host "HTTP/1.1^/"] 
                    append http-packet net-utils/export HTTP-Get-Header 
                    append http-packet "^/" 
                    net-utils/net-log http-packet 
                    insert port/sub-port http-packet 
                    continue-post/tunnel
                ] 
                system/words/set-modes port/sub-port [secure: true]
            ]
        ] 
        http-command: "GET" 
        HTTP-Get-Header: make object! [
            Accept: "*/*" 
            Connection: "close" 
            ;User-Agent: get in get in system/schemes port/scheme 'user-agent 
            User-Agent: "Rugby"
            Host: join port/host any [all [port/port-id (port/port-id <> 80) join #":" port/port-id] #]
        ] 
        if all [block? port/state/custom post-data: select port/state/custom 'header block? post-data] [
            HTTP-Get-Header: make HTTP-Get-Header post-data
        ] 
        HTTP-Header: make object! [
            Date: Server: Last-Modified: Accept-Ranges: Content-Encoding: Content-Type: 
            Content-Length: Location: Expires: Referer: Connection: Authorization: none
        ] 
        create-request: func [/local target user pass u] [
            http-version: "HTTP/1.0^/" 
            all [port/user port/pass HTTP-Get-Header: make HTTP-Get-Header [Authorization: join "Basic " enbase join port/user [#":" port/pass]]] 
            user: get in port/proxy 'user 
            pass: get in port/proxy 'pass 
            if all [generic-proxy? string? :user] [
                HTTP-Get-Header: make HTTP-Get-Header [
                    Proxy-Authorization: join "Basic " enbase join user [#":" pass]
                ]
            ] 
            if port/state/index > 0 [
                http-version: "HTTP/1.1^/" 
                HTTP-Get-Header: make HTTP-Get-Header [
                    Range: rejoin ["bytes=" port/state/index "-"]
                ]
            ] 
            target: next mold to-file join (join "/" either found? port/path [port/path] [""]) either found? port/target [port/target] [""] 
            post-data: none 
            if all [block? port/state/custom post-data: find port/state/custom 'post post-data/2] [
                http-command: "POST" 
                HTTP-Get-Header: make HTTP-Get-Header append [
                    Referer: either find port/url #"?" [head clear find copy port/url #"?"] [port/url] 
                    Content-Type: "application/x-www-form-urlencoded" 
                    Content-Length: length? post-data/2
                ] either block? post-data/3 [post-data/3] [[]] 
                post-data: post-data/2
            ] 
            http-packet: reform [http-command either generic-proxy? [port/url] [target] http-version] 
            append http-packet net-utils/export HTTP-Get-Header 
            append http-packet "^/" 
            if post-data [append http-packet post-data]
        ] 
        send-and-check: func [] [
            net-utils/net-log http-packet 
            insert port/sub-port http-packet 
            return
            ;write-io port/sub-port http-packet length? http-packet
            ;We don't care about forwards and such as it is 
            ;used for Rugby only

            ;continue-post
        ] 
        continue-post: func [/tunnel] [
            response-line: system/words/pick port/sub-port 1 
            net-utils/net-log response-line 
            either none? response-line [do error] [
                either none? result: select either tunnel [tunnel-actions] [response-actions] 
                response-code: to-integer second parse response-line none [
                    do error] [
                    net-utils/net-log mold result
                    do get result]
            ]
        ] 
        tunnel-actions: [
            200 tunnel-success
        ] 
        response-actions: [
            100 continue-post 
            200 success 
            201 success 
            204 success 
            206 success 
            300 forward 
            301 forward 
            302 forward 
            304 success 
            407 proxyauth
        ] 
        tunnel-success: [
            while [(line: pick port/sub-port 1) <> ""] [net-log line]
        ] 
        ;success: [
        ;    headers: make string! 500 
        ;    while [(line: pick port/sub-port 1) <> ""] [append headers join line "^/"] 
        ;    cookie-list: parse-cookies headers
        ;    port/locals/headers: headers: Parse-Header HTTP-Header headers 
        ;    port/locals/headers: make port/locals/headers [ cookies: cookie-list]
        ;    port/size: 0 
        ;    if querying [if headers/Content-Length [port/size: load headers/Content-Length]] 
        ;    if error? try [port/date: parse-header-date headers/Last-Modified] [port/date: none] 
        ;    port/status: 'file
        ;]

        success: copy [print "***SUCCES***"]
        
        error: [
            system/words/close port/sub-port 
            net-error reform ["Error.  Target url:" port/url "could not be retrieved.  Server response:" response-line]
        ] 
        forward: [
            page: copy "" 
            while [(str: pick port/sub-port 1) <> ""] [append page reduce [str newline]] 
            headers: Parse-Header HTTP-Header page 
            
            insert port/locals/list port/url 
            either found? headers/Location [
                either any [find/match headers/Location "http://" find/match headers/Location "https://"] [
                    port/path: port/target: port/port-id: none 
                    net-utils/URL-Parser/parse-url/set-scheme port to-url port/url: headers/Location 
                    ;port/scheme: 'HTTPR
                    port/port-id: any [port/port-id get in get in system/schemes port/scheme 'port-id]
                ] [
                    either (first headers/Location) = slash [port/path: none remove headers/Location] [either port/path [insert port/path "/"] [port/path: copy "/"]] 
                    port/target: headers/Location 
                    port/url: rejoin [lowercase to-string port/scheme "://" port/host either port/path [port/path] [""] either port/target [port/target] [""]]
                ] 
                if find/case port/locals/list port/url [net-error reform ["Error.  Target url:" port/url {could not be retrieved.  Circular forwarding detected}]] 
                system/words/close port/sub-port 
                build-port 
                http-get-header/Host: port/host
                create-request 
                send-and-check
            ] [
                do error]
        ] 
        proxyauth: [
            system/words/close port/sub-port 
            either all [generic-proxy? (not string? get in port/proxy 'user)] [
                port/proxy/user: system/schemes/http/proxy/user: port/proxy/user 
                port/proxy/pass: system/schemes/http/proxy/pass: port/proxy/pass 
                if not error? [result: get in system/schemes 'https] [
                    result/proxy/user: port/proxy/user 
                    result/proxy/pass: port/proxy/pass
                ]
            ] [
                net-error reform ["Error. Target url:" port/url {could not be retrieved: Proxy authentication denied}]
            ] 
            build-port 
            create-request 
            send-and-check
        ] 
        build-port 
        create-request 
        send-and-check
    ]
    close: func [port][system/words/close port/sub-port]
    write: func [
        "Default write operation called from buffer layer." 
        port "An open port spec" 
        data "Data to write"
    ][
        net-utils/net-log ["low level write of " port/state/num "bytes"] 
        write-io port/sub-port data port/state/num
    ]
    read: func [
        port "An open port spec" 
        data "A buffer to use for the read"
    ][
        net-utils/net-log ["low level read of " port/state/num "bytes"] 
        read-io port/sub-port data port/state/num
    ]
    get-sub-port: func [
        port "An open port spec"
    ][
        port/sub-port
    ]
    awake: func [
        port "An open port spec"
    ][
        none
    ]
    get-modes: func [
        port "An open port spec" 
        modes "A mode block"
    ][
        system/words/get-modes port/sub-port modes
    ]
    set-modes: func [
        port "An open port spec" 
        modes "A mode block"
    ][
        system/words/set-modes port/sub-port modes
    ]
    querying: false
    query: func [port][
        if not port/locals [
            querying: true 
            open port
        ] 
        none
    ]
]


net-utils/net-install HTTPR ctx-httpr 80
system/schemes/http: make system/schemes/http [user-agent: reform ["REBOL" system/version]]
