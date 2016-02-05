REBOL []

;Improved cookie support
parse-cookies: func [ {Parse a HTTP header for cookies and return them as a nested list} 
                      header [any-string!]
                      /local name-val
                      optionals cookie-rule
                      cookie-list cookie cookies                    
                    ]
[
  cookie-list: copy []
  cookies: copy []
  cookie-rule: [ thru "Set-Cookie:" copy c thru newline (append cookies c)]
  name-val: [ copy name to "=" skip copy val to ";" skip (append cookie  reduce [ "name" name "value" val])]
  optionals: [copy name to "=" skip [ copy val to ";" skip | copy val to newline ] (append cookie reduce [name val])]

  parse header [ some cookie-rule ]

  foreach entry cookies
  [
    cookie: copy []
    parse entry [ name-val [some optionals]]
    append/only cookie-list cookie
  ]
  return cookie-list
]



ctx-httpr: make object! [
    port-flags: 0
    open-check: none
    close-check: none
    write-check: none
    init: func [
        "Parse URL and/or check the port spec object" 
        port "Unopened port spec" 
        spec {Argument passed to open or make (a URL or port-spec)} 
        /local scheme
    ][
        if url? spec [net-utils/url-parser/parse-url port spec] 
        scheme: port/scheme 
        port/url: spec 
        if none? port/host [
            net-error reform ["No network server for" scheme "is specified"]
        ] 
        if none? port/port-id [
            net-error reform ["No port address for" scheme "is specified"]
        ]
    ]
    open-proto: func [
        {Open the socket connection and confirm server response.} 
        port "Initalized port spec" 
        /sub-protocol subproto 
        /secure 
        /generic 
        /locals sub-port data in-bypass find-bypass bp
    ][
        if not sub-protocol [subproto: 'tcp] 
        net-utils/net-log reduce ["Opening" to-string subproto "for" to-string port/scheme] 
        if not system/options/quiet [print ["connecting to:" port/host]] 
        find-bypass: func [host bypass /local x] [
            if found? host [
                foreach item bypass [
                    if any [
                        all [x: find/match/any host item tail? x]
                    ] [return true]
                ]
            ] 
            false
        ] 
        in-bypass: func [host bypass /local item x] [
            if any [none? bypass empty? bypass] [return false] 
            if not tuple? load host [host: form system/words/read join dns:// host] 
            either find-bypass host bypass [
                true
            ] [
                host: system/words/read join dns:// host 
                find-bypass host bypass
            ]
        ] 
        either all [
            port/proxy/host 
            bp: not in-bypass port/host port/proxy/bypass 
            find [socks4 socks5 socks] port/proxy/type
        ] [
            port/sub-port: net-utils/connect-proxy/sub-protocol port 'connect subproto
        ] [
            sub-port: system/words/open/lines compose [
                scheme: (to-lit-word subproto) 
                host: either all [port/proxy/type = 'generic generic bp] [port/proxy/host] [port/proxy/host: none port/host] 
                user: port/user 
                pass: port/pass 
                port-id: either all [port/proxy/type = 'generic generic bp] [port/proxy/port-id] [port/port-id]
            ] 
            port/sub-port: sub-port
        ] 
        if all [secure find [ssl tls] subproto] [system/words/set-modes port/sub-port [secure: true]] 
        port/sub-port/timeout: port/timeout 
        port/sub-port/user: port/user 
        port/sub-port/pass: port/pass 
        port/sub-port/path: port/path 
        port/sub-port/target: port/target 
        net-utils/confirm/multiline port/sub-port open-check 
        port/state/flags: port/state/flags or port-flags
    ]
    open: func [
        port "the port to open" 
        /local http-packet http-command response-actions success error response-line 
        target headers http-version post-data result generic-proxy? sub-protocol 
        build-port send-and-check create-request cookie-list][
        port/locals: make object! [list: copy [] headers: none] 
        generic-proxy?: all [port/proxy/type = 'generic not none? port/proxy/host] 
        build-port: func [] [
            sub-protocol: either port/scheme = 'https ['ssl] ['tcp] 
            open-proto/sub-protocol/generic port sub-protocol 
            ;port/url: rejoin [lowercase to-string port/scheme "://" port/host either port/port-id <> 80 [join #":" port/port-id] [copy ""] slash] 
            ;We need to change port/scheme to http to fool the world (httpr is no protocol in real life)
            port/url: rejoin [lowercase to-string 'http "://" port/host either port/port-id <> 80 [join #":" port/port-id] [copy ""] slash] 
            if found? port/path [append port/url port/path] 
            if found? port/target [append port/url port/target] 
            if sub-protocol = 'ssl [
                if generic-proxy? [
                    HTTP-Get-Header: make object! [
                        Host: join port/host any [all [port/port-id (port/port-id <> 80) join #":" port/port-id] #]
                    ] 
                    user: get in port/proxy 'user 
                    pass: get in port/proxy 'pass 
                    if string? :user [
                        HTTP-Get-Header: make HTTP-Get-Header [
                            Proxy-Authorization: join "Basic " enbase join user [#":" pass]
                        ]
                    ] 
                    http-packet: reform ["CONNECT" HTTP-Get-Header/Host "HTTP/1.1^/"] 
                    append http-packet net-utils/export HTTP-Get-Header 
                    append http-packet "^/" 
                    net-utils/net-log http-packet 
                    insert port/sub-port http-packet 
                    continue-post/tunnel
                ] 
                system/words/set-modes port/sub-port [secure: true]
            ]
        ] 
        http-command: "GET" 
        HTTP-Get-Header: make object! [
            Accept: "*/*" 
            Connection: "close" 
            ;User-Agent: get in get in system/schemes port/scheme 'user-agent 
            User-Agent: "Rugby"
            Host: join port/host any [all [port/port-id (port/port-id <> 80) join #":" port/port-id] #]
        ] 
        if all [block? port/state/custom post-data: select port/state/custom 'header block? post-data] [
            HTTP-Get-Header: make HTTP-Get-Header post-data
        ] 
        HTTP-Header: make object! [
            Date: Server: Last-Modified: Accept-Ranges: Content-Encoding: Content-Type: 
            Content-Length: Location: Expires: Referer: Connection: Authorization: none
        ] 
        create-request: func [/local target user pass u] [
            http-version: "HTTP/1.0^/" 
            all [port/user port/pass HTTP-Get-Header: make HTTP-Get-Header [Authorization: join "Basic " enbase join port/user [#":" port/pass]]] 
            user: get in port/proxy 'user 
            pass: get in port/proxy 'pass 
            if all [generic-proxy? string? :user] [
                HTTP-Get-Header: make HTTP-Get-Header [
                    Proxy-Authorization: join "Basic " enbase join user [#":" pass]
                ]
            ] 
            if port/state/index > 0 [
                http-version: "HTTP/1.1^/" 
                HTTP-Get-Header: make HTTP-Get-Header [
                    Range: rejoin ["bytes=" port/state/index "-"]
                ]
            ] 
            target: next mold to-file join (join "/" either found? port/path [port/path] [""]) either found? port/target [port/target] [""] 
            post-data: none 
            if all [block? port/state/custom post-data: find port/state/custom 'post post-data/2] [
                http-command: "POST" 
                HTTP-Get-Header: make HTTP-Get-Header append [
                    Referer: either find port/url #"?" [head clear find copy port/url #"?"] [port/url] 
                    Content-Type: "application/x-www-form-urlencoded" 
                    Content-Length: length? post-data/2
                ] either block? post-data/3 [post-data/3] [[]] 
                post-data: post-data/2
            ] 
            http-packet: reform [http-command either generic-proxy? [port/url] [target] http-version] 
            append http-packet net-utils/export HTTP-Get-Header 
            append http-packet "^/" 
            if post-data [append http-packet post-data]
        ] 
        send-and-check: func [] [
            net-utils/net-log http-packet 
            insert port/sub-port http-packet 
            return
            ;write-io port/sub-port http-packet length? http-packet
            ;We don't care about forwards and such as it is 
            ;used for Rugby only

            ;continue-post
        ] 
        continue-post: func [/tunnel] [
            response-line: system/words/pick port/sub-port 1 
            net-utils/net-log response-line 
            either none? response-line [do error] [
                either none? result: select either tunnel [tunnel-actions] [response-actions] 
                response-code: to-integer second parse response-line none [
                    do error] [
                    net-utils/net-log mold result
                    do get result]
            ]
        ] 
        tunnel-actions: [
            200 tunnel-success
        ] 
        response-actions: [
            100 continue-post 
            200 success 
            201 success 
            204 success 
            206 success 
            300 forward 
            301 forward 
            302 forward 
            304 success 
            407 proxyauth
        ] 
        tunnel-success: [
            while [(line: pick port/sub-port 1) <> ""] [net-log line]
        ] 
        ;success: [
        ;    headers: make string! 500 
        ;    while [(line: pick port/sub-port 1) <> ""] [append headers join line "^/"] 
        ;    cookie-list: parse-cookies headers
        ;    port/locals/headers: headers: Parse-Header HTTP-Header headers 
        ;    port/locals/headers: make port/locals/headers [ cookies: cookie-list]
        ;    port/size: 0 
        ;    if querying [if headers/Content-Length [port/size: load headers/Content-Length]] 
        ;    if error? try [port/date: parse-header-date headers/Last-Modified] [port/date: none] 
        ;    port/status: 'file
        ;]

        success: copy [print "***SUCCES***"]
        
        error: [
            system/words/close port/sub-port 
            net-error reform ["Error.  Target url:" port/url "could not be retrieved.  Server response:" response-line]
        ] 
        forward: [
            page: copy "" 
            while [(str: pick port/sub-port 1) <> ""] [append page reduce [str newline]] 
            headers: Parse-Header HTTP-Header page 
            
            insert port/locals/list port/url 
            either found? headers/Location [
                either any [find/match headers/Location "http://" find/match headers/Location "https://"] [
                    port/path: port/target: port/port-id: none 
                    net-utils/URL-Parser/parse-url/set-scheme port to-url port/url: headers/Location 
                    ;port/scheme: 'HTTPR
                    port/port-id: any [port/port-id get in get in system/schemes port/scheme 'port-id]
                ] [
                    either (first headers/Location) = slash [port/path: none remove headers/Location] [either port/path [insert port/path "/"] [port/path: copy "/"]] 
                    port/target: headers/Location 
                    port/url: rejoin [lowercase to-string port/scheme "://" port/host either port/path [port/path] [""] either port/target [port/target] [""]]
                ] 
                if find/case port/locals/list port/url [net-error reform ["Error.  Target url:" port/url {could not be retrieved.  Circular forwarding detected}]] 
                system/words/close port/sub-port 
                build-port 
                http-get-header/Host: port/host
                create-request 
                send-and-check
            ] [
                do error]
        ] 
        proxyauth: [
            system/words/close port/sub-port 
            either all [generic-proxy? (not string? get in port/proxy 'user)] [
                port/proxy/user: system/schemes/http/proxy/user: port/proxy/user 
                port/proxy/pass: system/schemes/http/proxy/pass: port/proxy/pass 
                if not error? [result: get in system/schemes 'https] [
                    result/proxy/user: port/proxy/user 
                    result/proxy/pass: port/proxy/pass
                ]
            ] [
                net-error reform ["Error. Target url:" port/url {could not be retrieved: Proxy authentication denied}]
            ] 
            build-port 
            create-request 
            send-and-check
        ] 
        build-port 
        create-request 
        send-and-check
    ]
    close: func [port][system/words/close port/sub-port]
    write: func [
        "Default write operation called from buffer layer." 
        port "An open port spec" 
        data "Data to write"
    ][
        net-utils/net-log ["low level write of " port/state/num "bytes"] 
        write-io port/sub-port data port/state/num
    ]
    read: func [
        port "An open port spec" 
        data "A buffer to use for the read"
    ][
        net-utils/net-log ["low level read of " port/state/num "bytes"] 
        read-io port/sub-port data port/state/num
    ]
    get-sub-port: func [
        port "An open port spec"
    ][
        port/sub-port
    ]
    awake: func [
        port "An open port spec"
    ][
        none
    ]
    get-modes: func [
        port "An open port spec" 
        modes "A mode block"
    ][
        system/words/get-modes port/sub-port modes
    ]
    set-modes: func [
        port "An open port spec" 
        modes "A mode block"
    ][
        system/words/set-modes port/sub-port modes
    ]
    querying: false
    query: func [port][
        if not port/locals [
            querying: true 
            open port
        ] 
        none
    ]
]


net-utils/net-install HTTPR ctx-httpr 80
system/schemes/http: make system/schemes/http [user-agent: reform ["REBOL" system/version]]
