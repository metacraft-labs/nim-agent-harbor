## Starts a private, real `ah server start`, for tests that check a client of
## Agent Harbor against the server itself: this repository's
## `test_real_server_*.nim`, and the consumers' live-source tests. It is test
## support, not part of the client: nothing in `nim_agent_harbor` imports it,
## and a consumer imports `nim_agent_harbor/testing/real_server` explicitly.
##
## The server is the installed `agent-harbor` package, or the binary named by
## `AH_SERVER_BIN`. Its state lives in a fresh directory under `/tmp` that is
## also its `HOME` and XDG base, so it never sees the operator's own
## configuration, sessions or credentials, and it listens on a free loopback
## port. Native only: it spawns a process and talks plain HTTP. The
## environment, the arguments and `probeTask` are `testing/server_launch`'s,
## shared with the Node harness (`testing/real_server_node`).

when defined(js):
  {.error: "nim_agent_harbor/testing/real_server starts a process; it is native only".}

import std/[monotimes, net, os, osproc, strtabs, strutils, tempfiles, times]
from std/httpclient import nil
from std/httpcore import nil
import nim_everywhere
import nim_agent_harbor
import ./server_launch

export server_launch

type RealServer* = object
  process*: Process
  root*: string
  baseUrl*: string

func toStdMethod(httpMethod: nim_everywhere.HttpMethod): httpcore.HttpMethod =
  case httpMethod
  of hmGet: httpcore.HttpGet
  of hmPost: httpcore.HttpPost
  of hmPut: httpcore.HttpPut
  of hmDelete: httpcore.HttpDelete

proc nativeTransport*(): HttpTransport =
  ## A blocking transport with a 10 s timeout, independent of the library's
  ## own native transport, so a defect there cannot hide behind itself.
  proc(req: HttpRequest): HttpResponse =
    let http = httpclient.newHttpClient(timeout = 10_000)
    defer: httpclient.close(http)
    for item in req.headers:
      httpcore.`[]=`(http.headers, item.name, item.value)
    let response = httpclient.request(http, req.url,
      httpMethod = req.httpMethod.toStdMethod, body = req.body)
    HttpResponse(status: httpclient.code(response).int,
      body: httpclient.body(response))

proc serverBinary*(): string =
  ## The server to start, or "" when none is installed.
  result = getEnv("AH_SERVER_BIN")
  if result.len == 0:
    result = findExe("ah")

proc freePort*(): Port =
  ## A loopback port no one listens on at the moment of the call.
  let socket = newSocket()
  defer: socket.close()
  socket.bindAddr(Port(0), "127.0.0.1")
  socket.getLocalAddr()[1]

proc stop*(server: RealServer)

proc startServer*(binary: string; apiKey = ""; port = Port(0)): RealServer =
  ## Starts the server and waits for `/healthz`. A non-empty `apiKey` turns
  ## REST authentication on (`AH_API_KEY`). `port` 0 picks a free one; a
  ## test that must know the address before the server exists (a client
  ## started first, or a server restarted at the same address) passes one.
  # Unix socket paths must fit in SUN_LEN (108 bytes), so the server's state
  # lives under a short directory rather than the (often long) temp dir.
  result.root = createTempDir("ahk", "", "/tmp")
  let root = result.root
  let port = if port == Port(0): freePort() else: port
  result.baseUrl = serverBaseUrl(port.int)
  let env = newStringTable(modeCaseSensitive)
  for (name, value) in serverEnv(root, getEnv("PATH"), apiKey, port.int):
    env[name] = value
  # The caller only owns the server once this returns, so a server that fails
  # to start or come up is stopped and its directory removed here.
  try:
    result.process = startProcess(binary, workingDir = root,
      args = serverArgs(root),
      env = env,
      options = {poParentStreams})

    # Monotonic, so a wall-clock step (NTP, suspend) cannot cut the wait short
    # or stretch it.
    let deadline = getMonoTime() + initDuration(seconds = 60)
    let transport = nativeTransport()
    while true:
      if not result.process.running:
        raise newException(IOError, "ah server exited with " &
          $result.process.peekExitCode & " before answering /healthz")
      try:
        if transport.request(newRequest(hmGet, result.baseUrl & "/healthz")).status == 200:
          return
      except CatchableError:
        discard
      if getMonoTime() > deadline:
        raise newException(IOError, "ah server did not answer /healthz within 60s")
      sleep(250)
  except CatchableError:
    result.stop()
    raise

proc stop*(server: RealServer) =
  if server.process != nil:
    # A server that already exited has been reaped, and signalling it would
    # raise ESRCH and hide the failure that ended it.
    if server.process.running:
      server.process.terminate()
    if server.process.waitForExit(10_000) == -1 and server.process.running:
      server.process.kill()
      discard server.process.waitForExit()
    server.process.close()
  if server.root.len > 0:
    removeDir(server.root)
