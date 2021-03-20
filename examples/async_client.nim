import asyncdispatch
import os
import strutils

import ../src/gemini

# Gemini client example
#
# compile with "nim c -d:ssl client.nim"
# run with ./client gemini://server/path
# or, to send a client certificate ./client gemini://server/path cert.pem privkey.pem
# a pair of cert, key can be generated with:
# $ openssl req -x509 -newkey rsa:4096 -keyout privkey.pem -out cert.pem -days 365
proc main() {.async.} =
  let 
    url = if paramCount() >= 1: paramStr(1) else: "gemini://gemini.circumlunar.space"
    certFile = if paramCount() >= 2: paramStr(2) else: ""
    keyFile = if paramCount() >= 3: paramStr(3) else: ""
  try:
    let client = newAsyncGeminiClient(certFile=certFile, keyFile=keyFile)
    let response = await client.request(url)
    defer: client.close()

    echo "status: " & $response.status
    echo "meta: " & response.meta
    echo "server certificate"
    echo "  is verified: " & $response.isVerified # certificate chain matched a known root certificate
    echo "  is self-signed: " & $response.isSelfSigned # certificate is self-signed
    echo "  common name: " & response.certificate.commonName() # CN field
    echo "  fingerprint: " & response.certificate.fingerprint() # sha256 digest
    echo "  content: " & $response.certificate # text representation of certificate
    echo "body: " & await response.body
  except GeminiError:
    echo getCurrentExceptionMsg()

waitFor main()
