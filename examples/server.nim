import asyncdispatch
import ../src/gemini

proc handleRequest(req: Request) {.async, gcsafe.} =
  await req.respond(Success, "text/gemini", "# Hello world")

var server = newGeminiServer(certFile = "fullchain.pem", keyFile = "privkey.pem")
waitFor server.serve(Port(1965), handleRequest, address = "::")
#waitFor server.serve(Port(1965), handleRequest)
