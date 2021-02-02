Gemini
=====

AsyncHttp-like building blocks for creating Gemini servers.

Unlike [geminim](https://github.com/ardek66/geminim), this does not handle serving files, cgi or file-based configuration. 

Example
-------

To use TLS, you need to provide a certFile and keyFile associated to your domain name.

```
import gemini

proc handle(req: Request) {.async, gcsafe.} =
  await req.respond(Success, "text/plain", "Hello world")

var server = newGeminiServer(certFile = "fullchain.pem", keyFile = "privkey.pem")
waitFor server.serve(Port(1965), handle, family = IpAddressFamily.IPv6)
```

Documentation
-------------

Create a new server:
```
proc newGeminiServer*(reuseAddr = true; reusePort = false, certFile = "", keyFile = ""): GeminiServer
```

Listen on a given port:
```
proc serve*(server: GeminiServer, port = Port(1965), callback: proc (request: Request): Future[void] {.closure, gcsafe.}, address = "", family = IpAddressFamily.IPv4) {.async.}
```

The callback is given a request which contains the url the client is requesting.

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

Warning
-------

The SSL implementation in NIM is not well tested.

Known Bugs
----------

Connecting with telnet as a client crashes the server with an SSL error
