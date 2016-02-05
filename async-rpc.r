REBOL []

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


