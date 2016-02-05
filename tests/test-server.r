REBOL [
  Title: "Rugby Test Cases, Server part"
  Short: "Rugby Test Cases, Server part"
  Author: ["Henrik Mikael Kristensen"]
  Copyright: "2007 - HMK Design"
  Filename: %test-server.r
  Version: 0.0.1
  Created: 15-Feb-2007
  Date: 15-Feb-2007
  License: {
    BSD (www.opensource.org/licenses/bsd-license.php)
    Use at your own risk.
  }
  Purpose: {
    Test cases for Rugby to reveal and test weaknesses and stability
  }
  History: []
  Keywords: []
]

;do http://www.hmkdesign.dk/rebol/rugby/rugby.r

do %/Volumes/c/rebol/rugby-pub/rugby.r

bigstring: mold system

; ---------- Feed the server with random data.
; This is to test the new buffer read function written by Henrik.

eat: func [data] [
  reform [length? data "received"]
]

; ---------- Feed the client with random data.
; This is to reveal a bug in Rugby that causes Bad Image Data at the client

feed: func [datatype [datatype!]] [
  to datatype encloak bigstring to-string checksum to-string now
]

; ---------- When the client is halted during execution, the 

hang-server: does [

]

; ---------- When the server is halted during execution of a call, client hangs

hang-client: does [
  "No hang!"
]

; serves on port 8000

serve/with [eat feed hang-server hang-client] tcp://:8000