REBOL []

do %rugby.r
set-ka: func [v][ka: :v]
i: does [serve/with  [add] tcp://:8003]
j: does [serve [ be-relay]]
k: does [ set-ka relay-to [ add 1 2] http://localhost:8002 http://localhost:8003]
l: does [ relay-to/async [add 1 3] http://localhost:8002 http://localhost:8003 :set-ka serve/with [] tcp://:9003]

halt
