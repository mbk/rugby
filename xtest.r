REBOL []

do %rugby.r
code: {add1: func [ n [number!]][n + 1]}
do get-rugby-service http://localhost:8002
extend-env [add1] code
