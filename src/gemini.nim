import asyncnet, asyncdispatch, net, uri, openssl, random

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

type GeminiServer* = ref object
  socket: AsyncSocket
  reuseAddr: bool
  reusePort: bool
  ctx: SSLContext

type Request* = object
  url: Uri
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
  server.ctx.wrapConnectedSocket(client, handshakeAsServer)
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
  result.ctx = newContext(certFile = certFile, keyFile = keyFile)
  
proc SSL_CTX_set_session_id_context(ctx: SslCtx, id: string, idLen: int) {.importc, dynlib: DLLSSLName}

proc sslSetSessionIdContext(ctx: SslContext, id: string = "") =
  SSL_CTX_set_session_id_context(ctx.context, id, id.len)

proc serve*(server: GeminiServer, port = Port(1965), callback: proc (request: Request): Future[void] {.closure, gcsafe.}, address = "", family = IpAddressFamily.IPv4) {.async.} =
  if family == IpAddressFamily.IPv6:
    server.socket = newAsyncSocket(domain = AF_INET6)
  else:
    server.socket = newAsyncSocket(domain = AF_INET)
  server.ctx.wrapSocket(server.socket)
  server.socket.setSockOpt(OptReuseAddr, server.reuseAddr)
  server.socket.setSockOpt(OptReusePort, server.reusePort)
  server.socket.bindAddr(port, address)
  server.ctx.wrapSocket(server.socket)
  # note: this is to prevent crash from opening with https browser
  server.ctx.sslSetSessionIdContext(id = $rand(1000000)) 
  server.socket.listen()

  while true:
    try:
      let client = await server.socket.accept()
      asyncCheck server.processClient(client, callback)
    except:
      echo getCurrentExceptionMsg()

when isMainModule:
  proc cb(req: Request) {.async, gcsafe.} =
    await req.respond(Success, "text/plain", "Hello world")

  var server = newGeminiServer(certFile = "fullchain.pem", keyFile = "privkey.pem")
  waitFor server.serve(Port(1965), cb, family = IpAddressFamily.IPv6)
  #waitFor server.serve(Port(1965), cb)
