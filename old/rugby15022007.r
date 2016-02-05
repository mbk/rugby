REBOL [
    Title: "Rugby"
    Date: now 
    Name: none
    Version: 5.0.1
    File: %rugby.r
    Home: none
    Author: ["Maarten Koopmans" "Henrik Mikael Kristensen"]
    Owner: none
    Rights: none
    Needs: "Command 2.0+ , Core 2.5+ , View 1.1+"
    Tabs: none
    Usage: none
    Purpose: {A high-performance, handler based, server framework and a rebol request broker...}
    Comment: {Many thanx to Ernie van der Meer for code scrubbing.
						4.0: Fixed non-blocking I/O bug in serve and poll-for-result.
						4.0: Added trim/all to handle large binaries in decompose-msg.
           -4.0: Added deferred and oneway refinements to sexec
           -4.0: Added automated stub generation and rugbys ervice import (thanks Ernie!)
           -4.0: Added /no-stubs refinement to serve and secure-serve
           -4.0: Added get-rugby-service function
           -4.0: Removed poll-for-result
           -4.1: Added get-result function
           -4.1: Added result-ready? function
           -4.1: Added get-secure-result function
           -4.1: Added secure-result-ready? function
           -4.1: Added http transport
           -4.1: All proxy functions now have refinement corresponding to rexec
           -4.2: Added non-blocking http
           -4.3: Added transparent error propagation.
    }
    History: none
    Language: none
    Type: none
    Content: none
    Email: maarten@vrijheid.net
]


current-port: none

hipe-serv: make object!
[
  ;Our list of server ports  
  server-ports: copy []
  ;Our server to handler mapping
  server-map: copy []
  ; The list of ports we wait/all for in our main loop
  port-q: copy []
  ; Mapping of ports to objects containg additional info
  object-q: copy []
  ; Restricted server list
  restricted-server: make block! 20
  ; Server restrictions?
  restrict: no
  ;The thread queue
  threads: copy []
  current-thread: none
  conn-timeout: 0:0:30

  max-thread-waiting: 0

  restrict-to: func
  [
    {Sets server restrictions. The server will only serve to machines with
     the IP-addresses found in the list.}
    r [any-block!] {List of IP-addresses to serve.}
  ]
  [
    restrict: yes
    append restricted-server r
  ]

  is-server?: func
  [
    {Check to see whether a given port is a server port.}
    p [port!]  
  ]
  [
    return found? find server-ports p
  ]

  add-thread: func [o [object!] {The thread to add}]
  [
    append hipe-serv/threads o
    o
  ]

  remove-thread: func [o [object!] {The tsak to remove}]
  [
    remove find head hipe-serv/threads o
  ]

  process-thread: func [/local do-thread]
  [
    do-thread: none
    ;Premature return
    if empty? hipe-serv/threads 
    [ return ]
    ;Are we initialized (cumbersome, but yes)
    if none? current-thread [ current-thread: head hipe-serv/threads]
    ;Are we at the end of the queue
    ;Note that this is an entry condition!
    if tail? current-thread [current-thread: head current-thread]
    ;What do we need to do
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

  allow?: func
  [
    {Checks if a connection to the specified IP-address is allowed.}
    ip [tuple!] {IP-address to check.}
  ]
  [
    return found? find restricted-server ip
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
    {cleans up after a client connection.}
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

  
  monitor: func
  [ 
    /interval t {the interval time} 
    /timeout t1 {The timeout time}
    /local int
  ]
  [
    if timeout [ hipe-serv/conn-timeout: t1 ]
    
    int: either interval [ t ][0:0:5]
    
    
    add-thread context 
    [
      code-pointer: 'start-monitor
      interv: int
      last-run: now
      clean-up: [ ]

      start-monitor:
      [
        set/any 'eee try [
        if now > (last-run + interv)
        [
          foreach [ p item] hipe-serv/object-q
          [
            if now > (item/lastaccess + hipe-serv/conn-timeout)
            [
              hipe-serv/stop item/port
            ]
          ]
          self/last-run: now
        ]]
      ]
    ]
  ]
  

  init-conn-port: func
  [
    {Initializes everything on network level.}
    serv [port!] {The server port}
    conn [port!] {The connection}
  ]
  [
    either restrict
    [
      either allow? conn/remote-ip
      [
        start serv conn
        return
      ]
      [
        close conn
        return
      ]
    ]
    ; No restrictions
    [
      start serv conn
      return
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
      either (is-server? item)      
      [
        either item/scheme = 'udp
        ;udp, so call our handler
        [ 
          temp-obj: get-handler item
          temp-obj copy item
        ]
        [ 
          init-conn-port item first item 
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
      portz: wait/all join port-q 0.005
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
        ;1 = size-read ; Size-read is sometimes 0, which would hang this line
        1 >= size-read ; Added by Henrik Mikael Kristensen
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
    cl offset ; Added by Henrik Mikael Kristensen
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
          request-length: 0 ; Added
          content-length: 0 ; by
          request-offset: 0 ; Henrik Mikael Kristensen
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
        ; ---------- Changed by Henrik Mikael Kristensen
        ; to use an adaptive read size up to 2048 bytes
        ; dramatically speeds up data reads pushed from client
        data-read: copy/part o/port offset: max 16 ud/request-length
        insert tail ud/request-data data-read
        ud/request-offset: ud/request-offset + offset
        all
        [
          not zero? ud/request-length
          ud/content-length < (ud/request-offset + ud/request-length)
          ;Slowly downgrade to 16 in read length as we approach the end
          until [
            ud/request-length: max 16 round/to/floor ud/request-length / 2 16
            any [
              ud/content-length >= (ud/request-offset + ud/request-length)
              ud/request-length = 16
            ]
          ]
          ;ud/request-length: 16
        ]
        all
        [
          zero? ud/request-length
          parse skip tail ud/request-data -50
          [
            thru "Content-Length: " copy cl to newline
            (
              ud/request-length:
                ; value must be between 16 and 4096
                min
                  2048 ; experimental value. max read size
                  max
                    16
                    subtract
                      round/to/floor ud/content-length: to-integer cl 16
                      16
            )
          ]
        ]
        if ud/request-read: request-read? skip tail ud/request-data -50
        [
          ud/request-length: 0
        ]
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
  
  ;Do we have restrictions active?
  if restrict [ rugby-server/restrict-to r ]

  ;On what port do we do the http proxy
  http-dest: make port! either with [ p ][ tcp://:8002 ]
  rugby-server/init-http-proxy http-dest
  
  rugby-server/init-rugby local-commands http-dest/port-id
  rugby-server/serve
]

server-magic: context
[
  async-rpc: func
  [
    u [url!] {The url to rpc to}
    code [block!] {The call to make}
    /secure-transport {Use secure transport}
    /deliver {The deliver the result to a function}
    f [any-function!] {The function to deliver to}  
    /on-error {Pass an error (disarmed) to an error handler}
    error-handler [any-function!]
    /timeout 
    the-out [time! integer!]
    timeout-action [block!]
    /local index
  ]
  [
    index: either secure-transport
    [ sexec/with/deferred code u]
    [ rexec/with/deferred code u]

    add-thread make object!
    [
      ;Code to check if our result is available.
      result-check: reduce either secure-transport
      [ [ 'secure-result-available? index ] ]
      [ [ 'result-available? index ] ]

      my-timeout: now + to-time the-out
      my-timeout-action: timeout-action
      
      ;Code to fetch our result
      result-fetch: reduce either secure-transport
      [ [ 'get-secure-result index ] ]
      [ [ 'get-result index ] ]

      ;the result value
      ret: none
      
      ;our (optional) delivery
      delivery: either deliver [ :f ][ false ]
      err: either on-error [ :error-handler ][ false ]
      
      clean-up: [] 
      
      ;The main loop
      main: 
      [
        ;Our result?
        if do result-check 
        [
          ;Yes! Fetch it
          if error? set/any 'ret try [do result-fetch]
          [ 
            if :err [ err disarm ret]
          ]
          ;optional delivery to a handler function
          if :delivery [ delivery ret]
          code-pointer: 'clean-up
        ]

        ;Timeout?
        if now > my-timeout [ 
          do my-timeout-action
          remove-request index
          code-pointer: 'clean-up
        ]     
      ]        

      code-pointer: 'main
    ]
  ]
];server-magic

set 'async-rpc get in server-magic 'async-rpc



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
      result-available? index
    ]
    return get-result index
  ]

  append-port: func
  [
    {Appends a port to the deffered-ports list}
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
    ret: do second decompose-msg res
    
    ;If it is an object it might be an error
    either object? ret
    [
      ;Have remake-error propage the error or the object
      remake-error ret
    ]
    [
      ret
    ]
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
    [ mold f-msg]
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
    return (checksum/secure second mold msg) = first msg
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

    cmd-block: compose-msg  command 
    cmd-string: rejoin [ {rugby-rq: [***} cmd-block
      {***] xtra-info: "1234567891011121314} ]
    port-spec: open/custom/direct/no-wait proxy reduce [ 'post cmd-string ]
    set-modes port-spec/sub-port [no-wait: true]
    return append-port port-spec    
  ]

  ;Used when we get an object back to provide transparent error propagation
  remake-error: func
  [
    {Remake an error from an object}
    disarmed [object!] {The object to remake}
    /local err-mask spec-length spec words
  ]
  [
    ;This determines if we have an error
    err-mask: [code type id arg1 arg2 arg3 near where ]
    
    ;If we have an error the object should have a certain layout
    ;in terms of fields
    either err-mask = intersect err-mask first disarmed
    [
      ;Get the length of the error spec
      spec-length: (length? first disarmed) - 3
      ;Make an empty error spec
      spec: make block! spec-length
      ;Get the defined words in the object
      words: copy/part skip first disarmed 2 spec-length
      ;Bind them to the values in the context of disarmed
      bind words in disarmed 'self
      ;Make the actual spec
      repeat word words [insert/only tail spec get word ]
      ;Throw the error
      return make error! spec
    ]
    [
      ;Not an error, return the original object
      disarmed
    ]
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

  get-rugby-service: func
  [
    target [url! ]
    /secure-code
    /local res fres
  ]
  [
    fres: copy []
    if not url? target [ make error! "Please specify a valid http url"]
    
    either secure-code
    [
      res: sexec/with [ get-secure-stubs ] target
    ]
    [
      res: rexec/with [get-stubs] target
    ]

    foreach e res
    [
      if block? e
      [ replace/all e {_*http*_} target ]
      append/only fres e
    ]
    fres 
  ]
]

set 'result-available? get in tunnel-ctx 'result-available?
set 'get-result get in tunnel-ctx 'get-result
set 'wait-for-result get in tunnel-ctx 'wait-for-result
set 'rexec get in tunnel-ctx 'rexec
set 'get-rugby-service get in tunnel-ctx 'get-rugby-service
set 'remove-request get in tunnel-ctx 'remove-request
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
    until [
      wait 0.003 ; fix for hang bug. see also wait-for-result
      secure-http-result-available? index ]
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

;Improved cookie support
parse-cookies: func [ {Parse a HTTP header for cookies and return them as a nested list} 
                      header [any-string!]
                      /local name-val
                      optionals cookie-rule
                      cookie-list cookie cookies                    
                    ]
[
  cookie-list: copy []
  cookies: copy []
  cookie-rule: [ thru "Set-Cookie:" copy c thru newline (append cookies c)]
  name-val: [ copy name to "=" skip copy val to ";" skip (append cookie  reduce [ "name" name "value" val])]
  optionals: [copy name to "=" skip [ copy val to ";" skip | copy val to newline ] (append cookie reduce [name val])]

  parse header [ some cookie-rule ]

  foreach entry cookies
  [
    cookie: copy []
    parse entry [ name-val [some optionals]]
    append/only cookie-list cookie
  ]
  return cookie-list
]



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


;A sample server test function
;Start serving with "serve [echo]"
echo: func [ e [string!]] [return e]

; Client test function. Shows how easy it is to do a remote exec
client-test: does [ rexec [echo "Rugby is great!"] ]








rugby-manager: context 
[
  start-heartbeat: func
  [
    {Starts a heart-beat thread}
    [catch]
    dest [url!] {The receiving heart-beat server}
    message [string!] {The heartbeat message}
    /interval {The heart-beat interval}
      t [time!] {The time between two heartbeats}
    /local it    
  ]
  [
    it: either interval [ t ][ 0:0:1]
    
    add-thread context compose/deep
    [
      last-beat: (now)
      iv: (it)
      port: (open dest)
      msg: (message)
      
      send-beat: 
      [
        
        if now > add last-beat it
        [
          last-beat: now
          
          insert port msg         
        ]

      ]

      code-pointer: 'send-beat
    ]
    true
  ]

  ;The default number of maximum threads
  mt: 100
  ;Default for using compression in Rugby
  use-compression: off
  
  ;The max-thread parse rule in the config dialect
  max-thread-rule: 
  [ 
    'set 'max-threads set mt integer!
    (hipe-serv/max-thread-waiting: mt)
  ]
  
  ;The default url for heartbeats
  u: udp://localhost:9900
  ;The default heartbeat message
  m: copy "ALIVE"
  ;The default repeating interval for the heartbeat
  i: 0:0:1
  
  ;The heartbeat rule of the configuration dialect
  heartbeat-rule:
  [
    'heartbeat 'on set u url! 'with 'message set m string! opt [ 'every set i time! ] 
    (hipe-serv/max-thread-waiting: 1 start-heartbeat/interval u m i)
  ]
  
  ;The use compression rule in the config dialect
  use-compression-rule: 
  [ 
    'use 'compression  
    ( tunnel-ctx/compression: rugby-server/compression: true )
  ]

  ;The no compression rule of the config dialect
  no-compression-rule: 
  [ 
    'no 'compression (tunnel-ctx/compression: rugby-server/compression:
    false) 
  ]

  o: none

  rsa-key-rule: [ 'use 'rsa-key set o object! (touchdown-server/key: o )]

  inv: 0:0:5
  tmo: 0:0:10

  monitor-rule: [ 'monitor opt [ 'every set inv time! ]  opt [ 'with 'timeout  set tmo time! ]
  (hipe-serv/monitor/interval/timeout inv tmo hipe-serv/max-thread-waiting:
  1 if inv > tmo [ print {Rugby warning: Useless timeout management!
  Checking interval should be less than timeout}])]
  

  ipa: 127.0.0.1

  
  ;The dialect itself ;-)
  main-rule: [ any [ max-thread-rule | no-compression-rule |
  use-compression-rule | heartbeat-rule | rsa-key-rule | monitor-rule 
  ]]

  

  ;The dialect parser
  set 'configure-rugby func
  [
    {Use the Rugby configuration dialect to configure Rugby}
    spec [block!] {The dialect spec}
    [catch]
  ] 
  [ 
    parse spec main-rule
  ]
]

do-after: func [
  {Executes the code after the given time}
  time [integer! time!]
  code [block!]
  /local
][
  add-thread context [
    exec-time: now + time
    exec-code: copy code

    code-pointer: 'main

    main: [
      if now >= exec-time
      [
        do code
        code-pointer: 'clean-up
      ]    
    ]
  ]
]

do-every: func [
  {Executes the code every time with the given interval}
  time [integer! time!]
  code [block!]
  /local
][
  add-thread context [
    exec-time: now + time
    exec-code: copy code
    interval: time

    code-pointer: 'main

    main: [
      if now >= exec-time
      [
        do code
        exec-time: now + time
      ]
    ]
  ]
]



make-resume: does [
  return use [port][
    port: current-port
    func [ value][
      rugby-server/write-result value port
      return
    ]
  ]
]

relay-timeout: 0:0:5

set 'be-relay func [
  code [block!]
  target [url!]
  results [block!]
  /local callback
][
  callback: make-resume
  async-rpc/deliver target code make-resume
  suspend
]

set 'relay-to func [
  code [block!]
  relay [url!]
  target [url!]
  /async 
  callback [any-function!]
][
  either async [
    async-rpc/deliver relay compose/only [ be-relay (code) (target)[]] :callback
  ][
    return rexec/with compose/only [ be-relay (code) (target)[]] relay
  ]
]




