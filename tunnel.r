REBOL[]

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
    until [result-available? index]
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
