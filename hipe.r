REBOL []

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
      portz: wait/all join port-q 0.002
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
