#!c:/rebol/rebol.exe -cs
REBOL []

;Not sure if this also works with sexec
;if you use sexec at least use a static key!
;Only works over http (not https)

do %rugby.r
cgi-serve: context [

  ; read post request
  process-rugby: func 
  [ 
    functions [block!]
    /http-port-number http-port
    /local len post-data the-request rugby-reply result
  
  ]
  [
    port: either http-port-number [ http-port][80]
    ;Initialize the allowed mezzanines
    append functions [ get-stubs]
    rugby-server/exec-env: copy functions
    
    ;generate stub code (it just might be a request for that)
    rugby-server/stubs: copy rugby-server/build-stubs/with rugby-server/exec-env port 
    
    ;Initialize the data
    the-request: make string! 4096
    rugby-reply: make string! 4096
    len: load any [ system/options/cgi/content-length "0"]
    post-data: make string! len
    while [ len > 0 ][ len: len - read-io system/ports/input post-data len ]
    replace/all post-data crlf "^/"
    
    ;print HTTP header
    prin {Content-type:  text/plain ^/^/}
    
    ;extract Rugby request
    if error? try [ the-request: rugby-server/decompose-msg rugby-server/get-request post-data ][print "hasta la vista baby!" quit]


    either attempt [rugby-server/check-msg the-request ]
    [
      if error? set/any 'result try
      [ rugby-server/safe-exec bind pick the-request 2 'do rugby-server/exec-env]
      [
        result:  disarm result
      ]

      ;Do we have a return value at all?
      either value? 'result
      [
         rugby-reply: rugby-server/compose-msg append/only copy [] get/any 'result
      ]       
      [  
         rugby-reply: rugby-server/compose-msg copy [unset!]
      ]
      insert rugby-reply copy {[***}
      append rugby-reply copy {***]}
      prin rugby-reply
    ]
    [
      print "Hasta la vista baby! That's no valid Rugby request"
    ]
    quit
  ]
]

cgi-serve/process-rugby/http-port-number [ now add ] 80
