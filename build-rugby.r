REBOL []


files: [ hipe server async-rpc tunnel touchdown_server touchdown_client httpr sample configure timers relays]


distrib: copy [
{REBOL [
    Title: "Rugby"
    Date: now 
    Name: none
    Version: 5.0.0
    File: %rugby.r
    Home: none
    Author: "Maarten Koopmans"
    Owner: none
    Rights: none
    Needs: "Command 2.0+ , Core 2.5+ , View 1.1+"
    Tabs: none
    Usage: none
    Purpose: {A high-performance, handler based, server framework and a rebol request broker...}
    Comment: {Many thanx to Ernie van der Meer for code scrubbing.
^-^-^-^-^-^-4.0: Fixed non-blocking I/O bug in serve and poll-for-result.
^-^-^-^-^-^-4.0: Added trim/all to handle large binaries in decompose-msg.
           -4.0: Added deferred and oneway refinements to sexec
           -4.0: Added automated stub generation and rugbys ervice import (thanks Ernie!)
           -4.0: Added /no-stubs refinement to serve and secure-serve
           -4.0: Added get-rugby-service function
           -4.0: Removed poll-for-result
           -4.1: Added get-result function
           -4.1: Added result-ready? function
           -4.1: Added get-secure-result function
           -4.1: Added secure-result-ready? function
           -4.1: Added http transport
           -4.1: All proxy functions now have refinement corresponding to rexec
           -4.2: Added non-blocking http
           -4.3: Added transparent error propagation.
    }
    History: none
    Language: none
    Type: none
    Content: none
    Email: maarten@vrijheid.net
]
}
]

foreach file files
[
  append distrib remove read/lines join to-file file ".r"
]


write/lines %rugby.r distrib
