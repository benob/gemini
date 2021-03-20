import asyncdispatch
import random
import nimcrypto
import strutils
import uri
import openssl
import streams
import net 

# temporary fix for missing api in net, asyncnet
import gemini/patched_net 
import gemini/patched_asyncnet 

export patched_asyncnet.`$`
export patched_asyncnet.commonName
export patched_asyncnet.fingerprint

export SslError
export Port 

type Status* = enum
  ## See https://gemini.circumlunar.space/docs/specification.html for documentation
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

type GeminiError* = object of CatchableError

when not defined(ssl):
  static:
    raise newException(GeminiError, "TLS support is not available. Compile with -d:ssl to enable.")

type GeminiClientBase[SocketType] = ref object
  socket: SocketType
  maxRedirects: Natural
  when SocketType is AsyncSocket:
    sslContext: net.SslContext
    bodyStream: FutureStream[string]
    parseBodyFut: Future[void]
  else:
    sslContext: patched_net.SslContext
    bodyStream: Stream
  
type GeminiClient* = GeminiClientBase[patched_net.Socket]
type AsyncGeminiClient* = GeminiClientBase[AsyncSocket]

type ResponseBase[ClientType] = ref object
  status*: Status
  meta*: string
  certificate*: PX509
  verification: int
  client: ClientType

type Response* = ResponseBase[GeminiClient]
type AsyncResponse* = ResponseBase[AsyncGeminiClient]

proc loadIdentityFile*(client: GeminiClient | AsyncGeminiClient; certFile, keyFile: string): bool =
  ## load a pair of certificate/key files in PEM format to be offered to the server
  ## to be used before connecting
  if client.sslContext.context.SSL_CTX_use_certificate_file(certFile, SSL_FILETYPE_PEM) != 1:
    return false
  if client.sslContext.context.SSL_CTX_use_PrivateKey_file(keyFile, SSL_FILETYPE_PEM) != 1:
    return false
  if client.sslContext.context.SSL_CTX_check_private_key() != 1:
    return false
  return true

proc newGeminiClient*(maxRedirects = 5, certFile = "", keyFile = ""): GeminiClient =
  ## optionally, a certificate-based identity can be offered to the server
  result = GeminiClient(maxRedirects: maxRedirects)
  result.bodyStream = newStringStream()
  result.sslContext = patched_net.newContext()
  # force use of custom verify_callback to allow for self-signed certificates
  result.sslContext.context.SSL_CTX_set_verify(SslVerifyPeer, verify_callback)
  if certFile != "" and keyFile != "":
    if not result.loadIdentityFile(certFile, keyFile):
      raise newException(GeminiError, "Failed to load certificate files.")

proc newAsyncGeminiClient*(maxRedirects = 5, certFile = "", keyFile = ""): AsyncGeminiClient =
  ## optionally, a certificate-based identity can be offered to the server
  result = AsyncGeminiClient(maxRedirects: maxRedirects)
  result.bodyStream = newFutureStream[string]("newAsyncGeminiClient")
  result.sslContext = net.newContext()
  # force use of custom verify_callback to allow for self-signed certificates
  result.sslContext.context.SSL_CTX_set_verify(SslVerifyPeer, verify_callback)
  if certFile != "" and keyFile != "":
    if not result.loadIdentityFile(certFile, keyFile):
      raise newException(GeminiError, "Failed to load certificate files.")

proc loadUrl(client: GeminiClient | AsyncGeminiClient, url: string): Future[Response | AsyncResponse] {.multisync.} =
  let uri = parseUri(url)
  let port = if uri.port == "": Port(1965) else: Port(parseInt(uri.port))
  if uri.scheme != "gemini":
    raise newException(GeminiError, url & ": scheme not supported")

  when client is AsyncGeminiClient:
    result = AsyncResponse(client: client)
    client.socket = await patched_asyncnet.dial(uri.hostname, port)
    patched_asyncnet.wrapConnectedSocket(client.sslContext, client.socket, net.handshakeAsClient, uri.hostname)
  else:
    result = Response(client: client)
    client.socket = patched_net.dial(uri.hostname, port)
    patched_net.wrapConnectedSocket(client.sslContext, client.socket, patched_net.handshakeAsClient, uri.hostname)
  
  # send data now to force TLS handshake to complete
  await client.socket.send(url & "\r\n")

  let handle = client.socket.getSslHandle()
  result.certificate = handle.SSL_get_peer_certificate()
  result.verification = handle.SSL_get_verify_result()

  let line = await client.socket.recvLine()
  if line.len < 3 or line[2] != ' ':
    raise newException(GeminiError, "unexpected response format: \"" & line & "\"")
  result.status = parseInt(line[0..1]).Status
  result.meta = line[3..^1]

  if result.status.int >= 30:
    client.socket.close()

proc request*(client: GeminiClient | AsyncGeminiClient, url: string): Future[Response | AsyncResponse] {.multisync.} =
  ## Retrive status and meta from a server for a given url, handling redirects.
  ## On success, the connection is kept open.
  ## Get the body with response.body
  var url = url
  result = await client.loadUrl(url)
  for i in 1..client.maxRedirects:
    if result.status == Redirect or result.status == TempRedirect:
      url = $combine(parseUri(url), parseUri(result.meta))
      result = await client.loadUrl(url)
    else:
      return
  client.socket.close()
  raise newException(GeminiError, "too many redirects")

proc body*(response: Response | AsyncResponse): Future[string] {.multisync.} =
  ## Get the body associated with a response.
  ## The connection is closed once the body has been retrieved.
  let client = response.client
  when response is AsyncResponse:
    while not patched_asyncnet.isClosed(client.socket):
      let data = await client.socket.recv(net.BufferSize)
      if data == "":
        client.socket.close()
        break # We've been disconnected.
      await client.bodyStream.write(data)
    client.bodyStream.complete()
  else:
    while not patched_net.isClosed2(client.socket):
      let data = await client.socket.recv(net.BufferSize)
      if data == "":
        client.socket.close()
        break # We've been disconnected.
      await client.bodyStream.write(data)
    client.bodyStream.setPosition(0)
  return await client.bodyStream.readAll()

proc close*(client: GeminiClient | AsyncGeminiClient) = 
  if not client.socket.isNil():
    client.socket.close()

type GeminiServerBase[SocketType] = ref object
  socket: SocketType
  reuseAddr: bool
  reusePort: bool
  when SocketType is AsyncSocket:
    sslContext: net.SslContext
  else:
    sslContext: patched_net.SslContext

type GeminiServer* = GeminiServerBase[patched_net.Socket]
type AsyncGeminiServer* = GeminiServerBase[AsyncSocket]

type RequestBase[SocketType] = ref object
  ## Request from a client.
  ## The url can be used to handle virtual hosts resource and query parameters
  url*: Uri
  certificate*: PX509
  verification: int
  client: SocketType

type Request* = RequestBase[patched_net.Socket]
type AsyncRequest* = RequestBase[AsyncSocket]

proc isSelfSigned*(transaction: Request | AsyncRequest | Response | AsyncResponse): bool =
  ## is true when the certificate is self-signed
  return transaction.verification == X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT or transaction.verification == X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN

proc isVerified*(transaction: Request | AsyncRequest | Response | AsyncResponse): bool =
  ## is true when the certificate chain is verified up to a known root certificate
  return transaction.verification == X509_V_OK

proc hasCertificate*(transaction: Request | AsyncRequest | Response | AsyncResponse): bool = not transaction.certificate.isNil

proc respond*(req: Request | AsyncRequest, status: Status, meta: string, body: string = "") {.multisync.} =
  ## Sends data back to a client as per the gemini protocol
  ## meta cannot be more than 1024 characters
  try:
    assert meta.len <= 1024
    await req.client.send($status.int & ' ' & meta & "\r\n")
    if status == Success:
      await req.client.send(body)
  except:
    echo getCurrentExceptionMsg()
    await req.client.send($Error.int & " INTERNAL ERROR\r\n")

proc processClient(server: GeminiServer, client: patched_net.Socket, callback: proc (request: Request) {.closure.}) =
  try:
    #patched_net.wrapConnectedSocket(server.sslContext, client, patched_net.handshakeAsServer)

    let line = client.recvLine()
    if line.len > 0:
      let 
        handle = client.getSslHandle()
        certificate = handle.SSL_get_peer_certificate()
        verification = handle.SSL_get_verify_result()
      var req = Request(url: parseUri(line), client: client, certificate: certificate, verification: verification)
      try:
        callback(req)
      except:
        echo getCurrentExceptionMsg()
        client.send($Error.int & " INTERNAL ERROR\r\n")
  except:
    echo getCurrentExceptionMsg()
  client.close()

proc processClient(server: AsyncGeminiServer, client: AsyncSocket, callback: proc (request: AsyncRequest): Future[void] {.async,closure.}) {.async.} =
  try:
    server.sslContext.wrapConnectedSocket(client, net.handshakeAsServer)

    let line = await client.recvLine()
    if line.len > 0:
      let 
        handle = client.getSslHandle()
        certificate = handle.SSL_get_peer_certificate()
        verification = handle.SSL_get_verify_result()
      var req = AsyncRequest(url: parseUri(line), client: client, certificate: certificate, verification: verification)
      try:
        await callback(req)
      except:
        echo getCurrentExceptionMsg()
        await client.send($Error.int & " INTERNAL ERROR\r\n")
  except:
    echo getCurrentExceptionMsg()
  client.close()

proc newGeminiServer*(reuseAddr = true; reusePort = false, certFile = "", keyFile = "", sessionId = ""): GeminiServer =
  ## Creates a new server, certFile and keyFile are used to handle the TLS handshake
  ## If a sessionId is not provided it is generated randomly and is used by TLS to resume sessions
  result = GeminiServer(reuseAddr: reuseAddr, reusePort: reusePort)
  result.sslContext = patched_net.newContext(certFile = certFile, keyFile = keyFile)
  # use custom verify_callback to allow for self-signed certificates
  result.sslContext.context.SSL_CTX_set_verify(SslVerifyPeer, verify_callback)
  var sessionId = sessionId
  if sessionId == "":
    sessionId = newString(32)
    randomize()
    discard randomBytes(sessionId)
  patched_net.`sessionIdContext=`(result.sslContext, sessionId)
  
proc newAsyncGeminiServer*(reuseAddr = true; reusePort = false, certFile = "", keyFile = "", sessionId = ""): AsyncGeminiServer =
  ## Creates a new server, certFile and keyFile are used to handle the TLS handshake
  ## If a sessionId is not provided it is generated randomly and is used by TLS to resume sessions
  result = AsyncGeminiServer(reuseAddr: reuseAddr, reusePort: reusePort)
  result.sslContext = net.newContext(certFile = certFile, keyFile = keyFile)
  # use custom verify_callback to allow for self-signed certificates
  result.sslContext.context.SSL_CTX_set_verify(SslVerifyPeer, verify_callback)
  var sessionId = sessionId
  if sessionId == "":
    sessionId = newString(32)
    randomize()
    discard randomBytes(sessionId)
  net.`sessionIdContext=`(result.sslContext, sessionId)
  
proc serve*(server: GeminiServer, port = Port(1965), callback: proc (request: Request) {.closure.}, address = "") =
  ## Starts serving requests. Each request is passed to the callback for processing
  ## If the listening addres contains ":", it is assumed to be IPv6
  ## Linux maps IPv4 requests to IPV6 if needed
  if address.find(":") >= 0:
    server.socket = patched_net.newSocket(domain = AF_INET6)
  else:
    server.socket = patched_net.newSocket(domain = AF_INET)
  server.sslContext.wrapSocket(server.socket)
  server.socket.setSockOpt(patched_net.OptReuseAddr, server.reuseAddr)
  server.socket.setSockOpt(patched_net.OptReusePort, server.reusePort)
  server.socket.bindAddr(port, address)
  server.socket.listen()

  while true:
    var client: patched_net.Socket
    #try:
    server.socket.accept(client)
    #except:
    #  echo getCurrentExceptionMsg()
    server.processClient(client, callback)

proc serve*(server: AsyncGeminiServer, port = Port(1965), callback: proc (request: AsyncRequest): Future[void] {.async,closure.}, address = "") {.async.} =
  ## Starts serving requests. Each request is passed to the callback for processing
  ## If the listening addres contains ":", it is assumed to be IPv6
  ## Linux maps IPv4 requests to IPV6 if needed
  if address.find(":") >= 0:
    server.socket = newAsyncSocket(domain = AF_INET6)
  else:
    server.socket = newAsyncSocket(domain = AF_INET)
  server.sslContext.wrapSocket(server.socket)
  server.socket.setSockOpt(net.OptReuseAddr, server.reuseAddr)
  server.socket.setSockOpt(net.OptReusePort, server.reusePort)
  server.socket.bindAddr(port, address)
  server.socket.listen()

  while true:
    var client: AsyncSocket
    try:
      client = await server.socket.accept()
    except:
      echo getCurrentExceptionMsg()
    asyncCheck server.processClient(client, callback)

