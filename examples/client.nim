import asyncdispatch
import ../src/gemini

proc main() {.async.} =
  try:
    let client = newGeminiClient()
    let response = await client.request("gemini://gemini.circumlunar.space")

    echo "status: " & $response.status
    echo "meta: " & response.meta
    echo "body: " & await response.body
  except GeminiError:
    echo getCurrentExceptionMsg()

waitFor main()
