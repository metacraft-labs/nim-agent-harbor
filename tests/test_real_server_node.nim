## A private, real `ah server start` from a Node process
## (`nim_agent_harbor/testing/real_server_node`), for the tests of a client
## that runs on Node: a desktop app's main process, which follows the server
## for its windows.
##
## No mocks: the server is the installed `ah` (or `AH_SERVER_BIN`), started
## with the same environment and arguments the native harness uses
## (`testing/server_launch`), and answered over real HTTP with Node's
## `fetch`. When no server binary is installed the suite says so and fails:
## a skipped suite here would read as a pass.
##
## Run with `nim js -d:nodejs -r` (Node).

when not defined(js):
  {.error: "test_real_server_node is the JavaScript (Node) harness's test".}

import std/[asyncjs, strutils]
import nim_agent_harbor/testing/real_server_node

proc exitProcess(code: int) {.importjs: "process.exit(#)".}
proc fetchStatusWith(url, auth: cstring): Future[int] {.importjs: """
  ((url, auth) => fetch(url, {headers: auth.length ? {Authorization: auth} : {}})
    .then(r => r.status, () => 0))(#, #)""".}
proc dirExists(path: cstring): bool {.importjs: "require('fs').existsSync(#)".}
proc processAlive(pid: int): bool {.importjs:
  "((pid) => { try { process.kill(pid, 0); return true; } catch (e) { return false; } })(#)".}

var checks, failed = 0
proc ck(cond: bool; name: string) =
  inc checks
  if cond: echo "  [OK] ", name
  else:
    inc failed
    echo "  [FAILED] ", name

proc run() {.async.} =
  echo "[Suite] a real server started from Node"
  let binary = serverBinaryNode()
  ck binary.len > 0, "a server binary is installed (`ah` on PATH or AH_SERVER_BIN)"
  if binary.len == 0: return
  let server = await startServerNode(binary, apiKey = "node-harness-key")
  ck server.baseUrl.startsWith("http://127.0.0.1:"), "it listens on loopback"
  ck (await fetchStatusWith(cstring(server.baseUrl & "/healthz"), "")) == 200,
    "it answers /healthz"
  ck (await fetchStatusWith(cstring(server.baseUrl & "/api/v1/sessions"),
       "ApiKey node-harness-key")) == 200,
    "its key is accepted"
  ck (await fetchStatusWith(cstring(server.baseUrl & "/api/v1/sessions"),
       "")) == 401,
    "a request without the key is refused"
  ck dirExists(cstring server.root), "its state lives in its own directory"
  let pid = server.pid
  await stopNode(server)
  ck not processAlive(pid), "stopping it ends the process"
  ck not dirExists(cstring server.root), "and removes its directory"

  echo "[Suite] the port a test chose"
  let port = await freePortNode()
  ck port > 0, "a free port is found"
  let fixed = await startServerNode(binary, port = port)
  ck fixed.baseUrl == "http://127.0.0.1:" & $port, "the server listens on it"
  await stopNode(fixed)

proc main() {.async.} =
  try:
    await run()
  except:
    inc failed
    echo "  [FAILED] the harness raised: ", getCurrentExceptionMsg()
  echo checks, " checks, ", failed, " failed"
  exitProcess(if failed == 0 and checks > 0: 0 else: 1)

discard main()
