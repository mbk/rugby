REBOL [ ]



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




