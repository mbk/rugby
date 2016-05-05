2016: Rugby revived for ARMv7 RRBOL 2 and 64 bit Linux REBOL 2.
MAJOR NEW FEATURE: adding code dynamically 


Works the way rugby always works, new docs will follow next week.
-do-after time code-block  ; a timer mezzanine when in the Rugby event loop

-do-every repeat-time code-block; a repetitive timer mezzanine when in the Rugby event loop 

-async-rpc/secure/deliver/on-error/timeout host code :callback error-handler-block timeout timeout-handler-block  ; a primitive for use in the Rugby event loop that does a non-blocking RPC and delivers the result to a callback. Can take timeouts and error-handlers as refinements

-current-port; global that gives access to the port of a Rugby request. 

-suspend; stops the execution of the currently handled Rugby request, can be handled later. Easy to use in combination with async-rpc for chaining RPC requests or building relays

-added a cgi script, ready to use on at least Apache and type something like: a: context get-rugby-service http://localhost/cgi-bin/rugby-cgi.cgi a/now
or rexec/with [add 3 4] http://localhost/cgi-bin/rugby-cgi.cgi
