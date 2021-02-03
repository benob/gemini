Gemini
=====

AsyncHttp-like building blocks for creating Gemini servers and clients.

Unlike [geminim](https://github.com/ardek66/geminim), this library does not handle serving files, cgi or configuration. 

Example
-------

Since Gemini requires TLS, you have to provide a certFile and keyFile associated to your domain name.

Example server:
```
import asyncdispatch
import gemini

proc handle(req: Request) {.async, gcsafe.} =
  await req.respond(Success, "text/plain", "Hello world")

var server = newGeminiServer(certFile = "fullchain.pem", keyFile = "privkey.pem")
waitFor server.serve(Port(1965), handle)
```

Example client:
```
import asyncdispatch
import gemini

proc main() {.async.} =
  try:
    let client = newGeminiClient()
    let response = await client.request("gemini://gemini.circumlunar.space")

    echo "status: " & $response.status
    echo "meta: " & response.meta
    echo "body: " & await response.body
  except GeminiError:
    echo getCurrentExceptionMsg()

waitFor main()
```

Documentation
-------------

See [https://gemini.circumlunar.space/docs/specification.html](https://gemini.circumlunar.space/docs/specification.html) for the protocol specification.

Create a new server:
```
proc newGeminiServer*(reuseAddr = true; reusePort = false, certFile = "", keyFile = ""): GeminiServer
```

Listen on a given port:
```
proc serve*(server: GeminiServer, port = Port(1965), callback: proc (request: Request): Future[void] {.closure, gcsafe.}, address = "") {.async.}
```

The callback is given a request which contains the url the client is requesting.
Note that when address contains a column, ":" the code assumes that you are specifying an IPv6 address (such as :: or ::1 which correspond to 0.0.0.0 and 127.0.0.1). 

Use respond() to send back a response:
```
proc respond*(req: Request, status: Status, meta: string, body: string = "") {.async, gcsafe.}
```

Supported status codes:
```
type Status* = enum
  Input = 10
  SensitiveInput = 11
  Success = 20
  TempRedirect = 30
  Redirect = 31
  TempError = 40
  ServerUnavailable = 41
  CGIError = 42
  ProxyError = 43
  Slowdown = 44
  Error = 50
  NotFound = 51
  Gone = 52
  ProxyRefused = 53
  MalformedRequest = 59
  CertificateRequired = 60
  CertificateUnauthorized = 61
  CertificateNotValid = 62
```

To create a new client:
```
proc newGeminiClient*(maxRedirects = 5): GeminiClient
```

Then you can submit a request to a "gemini://" url
```
proc request*(client: GeminiClient, url: string): Future[Response] {.async, gcsafe.}
```

The response contains two fields: the returned status code and the associated meta.
Redirects are handled.

You cat get the response body with:
```
proc body*(response: Response): Future[string] {.async, gcsafe.}
```

If an exception occurs such as a protocol error, you will get a GeminiError exception.

Warning
-------

The SSL implementation in NIM is not well tested, it may contain vulnerabilities.

Known Bugs
----------

Connecting with telnet as a client crashes the server with an SSL error

