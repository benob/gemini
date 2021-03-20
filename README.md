Gemini
=====

Building blocks for creating Gemini servers and clients.

Unlike [geminim](https://github.com/ardek66/geminim), this library does not handle serving files, cgi or configuration. 

Example
-------

This library supports both Socket and AsyncSocket servers and clients. The async variants are prefixed with Async.
Since Gemini requires TLS, you have to provide a certificate and private key associated with your domain name.

Example server:
```
import gemini

proc handle(req: Request) =
  await req.respond(Success, "text/gemini", "# Hello world")

var server = newGeminiServer(certFile = "fullchain.pem", keyFile = "privkey.pem")
server.serve(Port(1965), handle)
```

Example async server:
```
import asyncdispatch
import gemini

proc handle(req: AsyncRequest) {.async.} =
  await req.respond(Success, "text/gemini", "# Hello world")

var server = newAsyncGeminiServer(certFile = "fullchain.pem", keyFile = "privkey.pem")
waitFor server.serve(Port(1965), handle)
```

Example client:
```
import gemini

try:
  let client = newGeminiClient()
  let response = await client.request("gemini://gemini.circumlunar.space")

  echo "status: " & $response.status
  echo "meta: " & response.meta
  echo "body: " & response.body
except GeminiError:
  echo getCurrentExceptionMsg()
```

Example async client:
```
import asyncdispatch
import gemini

proc main() {.async.} =
  try:
    let client = newAsyncGeminiClient()
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
proc newAsyncGeminiServer*(reuseAddr = true; reusePort = false, certFile = "", keyFile = ""): AsyncGeminiServer
```

Listen on a given port:
```
proc serve*(server: GeminiServer, port = Port(1965), callback: proc (request: Request) {.closure.}, address = "")
proc serve*(server: AsyncGeminiServer, port = Port(1965), callback: proc (request: AsyncRequest): Future[void] {.closure.}, address = "") {.async.}
```

The callback is given a request which contains the url requested and a certificate if the client provided one.

Note that when address contains a column, ":" the code assumes that you are specifying an IPv6 address (such as :: or ::1 which correspond to 0.0.0.0 and 127.0.0.1). 
On Linux hosts, IPv4 requests are automatically mapped to IPv6 when listening to "::".
If the request url cannot be parsed, the server replies with status 50 INTERNAL ERROR.

Use respond() to send back a response:
```
proc respond*(req: Request, status: Status, meta: string, body: string = "")
proc respond*(req: AsyncRequest, status: Status, meta: string, body: string = "") {.async.}
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
proc newGeminiClient*(maxRedirects = 5, certFile = "", keyFile = ""): GeminiClient
proc newAsyncGeminiClient*(maxRedirects = 5, certFile = "", keyFile = ""): AsyncGeminiClient
```
You can provide a certFile and keyFile to be sent along the query.

Then you can submit a request to a "gemini://" url
```
proc request*(client: GeminiClient, url: string): Response
proc request*(client: AsyncGeminiClient, url: string): Future[AsyncResponse] {.async.}
```

The response contains three fields: the returned status code and the associated meta, and the server certificate. Redirects are handled.

You cat get the response body with:
```
proc body*(response: Response): string 
proc body*(response: Response): Future[string] {.async.}
```

If an exception occurs such as a protocol error, you will get a GeminiError exception.

Working with certificates
-------------------------

Both requests and responses have a few functions for handling certificates:
* `hasCertificate()` is true when there was a certificate
* `isVerified()` is true when the certificate chain was verfied up to a known root (as with a https client)
* `isSelfSigned()` is true when the certificate is self signed

You are supposed to handle self-signed certificates in a "Trust On First Use" fashion by building a whitelist like openssh.

You can inspect a certificate with `$req.certificate`, get the associated common name with `req.certificate.commonName()`, and get a sha256 fingerprint with `req.certificate.fingerprint()`.

Warning
-------

The TLS implementation in Nim is not well tested, it may contain vulnerabilities.
Note that the current code is too permissive and accepts SSL2/SSL3 handshakes.

Also, since net/asyncnet do not expose the underlying SSL sockets, we use a terrible hack which complexifies the code quite a bit.
See [https://github.com/nim-lang/Nim/issues/17021](https://github.com/nim-lang/Nim/issues/17021) for details.

Todo
----

- [x] Handle client certificates
- [x] Trust self-signed certificates
- [x] Non-async interface
- [ ] Parse text/gemini
