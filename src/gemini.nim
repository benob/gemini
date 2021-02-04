import asyncdispatch
import asyncnet
import net
import openssl
import random
import strutils
import uri

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

type GeminiError* = object of IOError

when not defined(ssl):
  static:
    raise newException(GeminiError, "SSL support is not available. Compile with -d:ssl to enable.")

type GeminiClient* = ref object
  socket: AsyncSocket
  sslContext: SSLContext
  bodyStream: FutureStream[string]
  maxRedirects: Natural

type Response* = ref object
  status*: Status
  meta*: string
  client: GeminiClient

proc newGeminiClient*(maxRedirects = 5): GeminiClient =
  result = GeminiClient(maxRedirects: maxRedirects)
  result.sslContext = newContext(verifyMode = CVerifyNone)

proc loadUrl(client: GeminiClient, url: string): Future[Response] {.async, gcsafe.} =
  result = Response(client: client)
  result.client = client
  let uri = parseUri(url)
  let port = if uri.port == "": Port(1965) else: Port(parseInt(uri.port))
  if uri.scheme != "gemini":
    raise newException(GeminiError, url & ": scheme not supported")
  client.socket = await asyncnet.dial(uri.hostname, port)
  client.sslContext.wrapConnectedSocket(client.socket, handshakeAsClient, uri.hostname)
  await client.socket.send(url & "\r\n")
  let line = await client.socket.recvLine()
  if line[2] != ' ':
    raise newException(GeminiError, "unexpected response format")
  result.status = parseInt(line[0..1]).Status
  result.meta = line[3..^1]

  if result.status.int >= 30:
    client.socket.close()

proc request*(client: GeminiClient, url: string): Future[Response] {.async, gcsafe.} =
  result = await client.loadUrl(url)
  for i in 1..client.maxRedirects:
    if result.status == Redirect or result.status == TempRedirect:
      result = await client.loadUrl(result.meta)
    else:
      return
  raise newException(GeminiError, "too many redirects")

proc body*(response: Response): Future[string] {.async, gcsafe.} =
  let client = response.client
  client.bodyStream = newFutureStream[string]("body")
  while not client.socket.isClosed():
    let data = await client.socket.recv(net.BufferSize)
    if data == "":
      client.socket.close()
      break # We've been disconnected.
    await client.bodyStream.write(data)
  client.bodyStream.complete()
  return await client.bodyStream.readAll()

type GeminiServer* = ref object
  socket: AsyncSocket
  reuseAddr: bool
  reusePort: bool
  sslContext: SSLContext

type Request* = object
  url*: Uri
  client: AsyncSocket

proc respond*(req: Request, status: Status, meta: string, body: string = "") {.async, gcsafe.} =
  assert meta.len <= 1024
  try:
    await req.client.send($status.int & ' ' & meta & "\r\n")
    if status == Success:
      await req.client.send(body)
  except:
    await req.client.send("40 INTERNAL ERROR\r\n")
    echo getCurrentExceptionMsg()

proc processClient(server: GeminiServer, client: AsyncSocket, callback: proc (request: Request): Future[void] {.closure, gcsafe.}) {.async.} =
  server.sslContext.wrapConnectedSocket(client, handshakeAsServer)
  let line = await client.recvLine()
  if line.len > 0:
    var req = Request(url: parseUri(line), client: client) 
    try:
      await callback(req)
    except:
      await client.send("40 INTERNAL ERROR\r\n")
      echo getCurrentExceptionMsg()
  client.close()

proc newGeminiServer*(reuseAddr = true; reusePort = false, certFile = "", keyFile = ""): GeminiServer =
  result = GeminiServer(reuseAddr: reuseAddr, reusePort: reusePort)
  result.sslContext = newContext(certFile = certFile, keyFile = keyFile)
  
# copied from geminim
proc SSL_CTX_set_session_id_context(sslContext: SslCtx, id: string, idLen: int) {.importc, dynlib: DLLSSLName}

proc sslSetSessionIdContext(sslContext: SslContext, id: string = "") =
  SSL_CTX_set_session_id_context(sslContext.context, id, id.len)

proc serve*(server: GeminiServer, port = Port(1965), callback: proc (request: Request): Future[void] {.closure, gcsafe.}, address = "") {.async.} =
  if address.find(":") >= 0:
    server.socket = newAsyncSocket(domain = AF_INET6)
  else:
    server.socket = newAsyncSocket(domain = AF_INET)
  server.sslContext.wrapSocket(server.socket)
  server.socket.setSockOpt(OptReuseAddr, server.reuseAddr)
  server.socket.setSockOpt(OptReusePort, server.reusePort)
  server.socket.bindAddr(port, address)
  server.sslContext.wrapSocket(server.socket)
  # note: this is to prevent crash from opening with https browser
  server.sslContext.sslSetSessionIdContext(id = $rand(1000000)) 
  server.socket.listen()

  while true:
    try:
      let client = await server.socket.accept()
      await server.processClient(client, callback)
    except:
      echo getCurrentExceptionMsg()

