REBOL []


;A sample server test function
;Start serving with "serve [echo]"
echo: func [ e [string!]] [return e]

; Client test function. Shows how easy it is to do a remote exec
client-test: does [ rexec [echo "Rugby is great!"] ]







