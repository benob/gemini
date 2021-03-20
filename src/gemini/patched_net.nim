include net

proc getSslHandle*(socket: Socket): SslPtr =
  return socket.sslHandle

proc isClosed2*(socket: Socket): bool = 
  socket.fd == osInvalidSocket

