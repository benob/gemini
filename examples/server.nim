import os
import ../src/gemini

# Gemini server example
# 
# compile with nim c -d:ssl server.nim
# you need a pair of certificate and private key, which can be generated with openssl
# $ openssl req -x509 -newkey rsa:4096 -keyout privkey.pem -out cert.pem -days 365
# run with ./server cert.pem privkey.pem
proc handleRequest(request: Request) =
  if request.url.path == "/auth":
    echo request.url.path
    if not request.hasCertificate():
      request.respond(CertificateRequired, "CLIENT CERTIFICATE REQUIRED")
    elif not (request.isVerified() or request.isSelfSigned()):
      request.respond(CertificateRequired, "CERTIFICATE NOT VALID")
    else:
      echo request.certificate.fingerprint()
      request.respond(Success, "text/gemini", "# Certificate accepted\nHello " & request.certificate.commonName())
  else:
    request.respond(Success, "text/gemini", "# Hello world")

var certFile = if paramCount() >= 1: paramStr(1) else: "cert.pem"
var keyFile = if paramCount() >= 2: paramStr(2) else: "privkey.pem"
var server = newGeminiServer(certFile = certFile, keyFile = keyFile)
server.serve(Port(1965), handleRequest, address = "::")
# if you don't have IPv6, use that line
#waitFor server.serve(Port(1965), handleRequest)
