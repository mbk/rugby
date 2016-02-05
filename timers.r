REBOL [ ]

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
