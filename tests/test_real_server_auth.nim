## API-key authentication against a real Agent Harbor REST server.
##
## The fake transport in `nim_agent_harbor/fake.nim` only models the header
## contract; this test proves it against the server itself. It starts
## `ah server start` (the installed `agent-harbor` package, or the binary named
## by `AH_SERVER_BIN`) with `AH_API_KEY` set, which turns REST authentication
## on, and checks that:
##
## - the client's `apiKeyAuth` creates a task (201);
## - `X-API-Key: <key>`, the header earlier client versions sent, gets 401;
## - a request without credentials gets 401, so the server really enforces auth.
##
## When no `ah` binary is available the test is skipped with the reason
## printed, so hosts without Agent Harbor stay green. Native only: it spawns a
## process and talks plain HTTP.

import std/[json, net, os, osproc, strtabs, strutils, tempfiles, times]
from std/httpclient import nil
from std/httpcore import nil
import unittest
import nim_everywhere
import nim_agent_harbor

const apiKey = "nim-agent-harbor-test-key"

func toStdMethod(httpMethod: nim_everywhere.HttpMethod): httpcore.HttpMethod =
  case httpMethod
  of hmGet: httpcore.HttpGet
  of hmPost: httpcore.HttpPost
  of hmPut: httpcore.HttpPut
  of hmDelete: httpcore.HttpDelete

proc nativeTransport(): HttpTransport =
  proc(req: HttpRequest): HttpResponse =
    let http = httpclient.newHttpClient(timeout = 10_000)
    defer: httpclient.close(http)
    for item in req.headers:
      httpcore.`[]=`(http.headers, item.name, item.value)
    let response = httpclient.request(http, req.url,
      httpMethod = req.httpMethod.toStdMethod, body = req.body)
    HttpResponse(status: httpclient.code(response).int,
      body: httpclient.body(response))

proc serverBinary(): string =
  result = getEnv("AH_SERVER_BIN")
  if result.len == 0:
    result = findExe("ah")

proc freePort(): Port =
  let socket = newSocket()
  defer: socket.close()
  socket.bindAddr(Port(0), "127.0.0.1")
  socket.getLocalAddr()[1]

type RealServer = object
  process: Process
  root: string
  baseUrl: string

proc startServer(binary: string): RealServer =
  # Unix socket paths must fit in SUN_LEN (108 bytes), so the server's state
  # lives under a short directory rather than the (often long) temp dir.
  result.root = createTempDir("ahk", "", "/tmp")
  let root = result.root
  let port = freePort()
  result.baseUrl = "http://127.0.0.1:" & $port.int
  let env = newStringTable(modeCaseSensitive)
  env["PATH"] = getEnv("PATH")
  env["HOME"] = root
  for name in ["XDG_RUNTIME_DIR", "XDG_STATE_HOME", "XDG_CONFIG_HOME",
      "XDG_DATA_HOME", "XDG_CACHE_HOME"]:
    env[name] = root / name.toLowerAscii()
  env["AH_API_KEY"] = apiKey
  env["AH_REST_HOST"] = "127.0.0.1"
  env["AH_REST_PORT"] = $port.int
  # `--task-manager-sock` places the task-manager socket explicitly. Without
  # it the server derives the path from XDG_RUNTIME_DIR and refuses any base
  # whose ancestors are not owned by root or the current user, which is the
  # case inside user-namespace sandboxes. `--acp-agent-cmd true` satisfies the
  # requirement for at least one ACP agent; no agent is ever started.
  result.process = startProcess(binary, workingDir = root,
    args = ["server", "start",
      "--acp-uds", root / "acp.sock",
      "--task-manager-sock", root / "tm.sock",
      "--acp-agent-cmd", "true"],
    env = env,
    options = {poParentStreams})

  let deadline = epochTime() + 60
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
    if epochTime() > deadline:
      raise newException(IOError, "ah server did not answer /healthz within 60s")
    sleep(250)

proc stop(server: RealServer) =
  if server.process != nil:
    server.process.terminate()
    if server.process.waitForExit(10_000) == -1 and server.process.running:
      server.process.kill()
      discard server.process.waitForExit()
    server.process.close()
  if server.root.len > 0:
    removeDir(server.root)

proc taskRequest(repoDir: string): CreateTaskRequest =
  CreateTaskRequest(
    prompt: "authentication probe",
    repo: RepoConfig(mode: "git", url: "file://" & repoDir, branch: "main"),
    runtime: defaultRuntime(),
    workspacePath: repoDir,
    sandbox: defaultSandbox(),
    delivery: DeliveryConfig(mode: "branch"),
    agents: @[AgentConfig(
      agent: AgentSoftware(software: "acp", version: "latest"),
      model: "mock",
      count: 1,
      acpStdioLaunchCommand: AcpStdioLaunchCommand(binary: "true"))],
    output: defaultOutput(),
    labels: newJObject())

suite "real ah-rest-server API-key authentication":
  let binary = serverBinary()

  test "the server accepts Authorization: ApiKey and rejects X-API-Key":
    if binary.len == 0:
      echo "SKIPPED: no Agent Harbor server binary: `ah` is not on PATH and " &
        "AH_SERVER_BIN is unset"
      skip()
    else:
      let server = startServer(binary)
      defer: server.stop()
      let repoDir = server.root / "repo"
      createDir(repoDir)
      let body = $taskToJson(taskRequest(repoDir))
      let jsonHeader = header("Content-Type", "application/json; charset=utf-8")
      let transport = nativeTransport()
      let tasksUrl = server.baseUrl & "/api/v1/tasks"

      let anonymous = transport.request(newRequest(hmPost, tasksUrl, body,
        @[jsonHeader]))
      check anonymous.status == 401

      let legacy = transport.request(newRequest(hmPost, tasksUrl, body,
        @[jsonHeader, header("X-API-Key", apiKey)]))
      check legacy.status == 401

      var statuses: seq[int] = @[]
      let recording: HttpTransport = proc(req: HttpRequest): HttpResponse =
        result = transport.request(req)
        statuses.add result.status
      let client = newHarborClient(server.baseUrl, recording, apiKeyAuth(apiKey))
      let created = client.createTask(taskRequest(repoDir))
      check statuses == @[201]
      check created.taskId.len > 0
      check created.sessionIds.len == 1
