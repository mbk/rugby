REBOL []

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
