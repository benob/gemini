import asyncdispatch
import os

import ../src/gemini

proc main() {.async.} =
  let url =
    if paramCount() >= 1:
      paramStr(1)
    else:
      "gemini://gemini.circumlunar.space"
  try:
    let client = newGeminiClient()
    let response = await client.request(url)

    echo "status: " & $response.status
    echo "meta: " & response.meta
    echo "body: " & await response.body
  except GeminiError:
    echo getCurrentExceptionMsg()

waitFor main()
