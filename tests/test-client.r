REBOL [
  Title: "Rugby Test Cases, Client part"
  Short: "Rugby Test Cases, Client part"
  Author: ["Henrik Mikael Kristensen"]
  Copyright: "2007 - HMK Design"
  Filename: %test-client.r
  Version: 0.0.1
  Created: 15-Feb-2007
  Date: 15-Feb-2007
  License: {
    BSD (www.opensource.org/licenses/bsd-license.php)
    Use at your own risk.
  }
  Purpose: {}
  History: []
  Keywords: []
]

; The test is meant to be run in two REBOL consoles on the same machine.

do http://www.hmkdesign.dk/rebol/rugby/rugby.r

net: context get-rugby-service http://localhost:8000

print "Connected to Test Server"

; ---------- Delivers from 1 to 1500000 bytes to the server in one byte increments. This may take 24-48 hours to complete.

dinner: has [str] [
  str: head repeat i 108000 [insert "" "a"]
  for i 1 1500000 1 [
    print net/eat head insert str "a"
  ]
]

; this will hang the server right after EOD, because of an UNTIL bug
; this should be fixed now

crash3810: does [
  print net/eat head loop 3810 [insert "" "a"]
]

; if read size of 4096 bytes is used in the server, this will hang it with 100% cpu. Does not occur if read size is 2048 bytes.

crash8680: does [
  print net/eat head loop 3810 [insert "" "a"]
]

; this is manipulated to halt the client during a transfer to simulate that the client has disconnected. This is to study what it takes for the server to handle a disconnection gracefully.

hang-client: does [
  net2: make net [
    hang-client
  ]
  get in net2 hang-client
]