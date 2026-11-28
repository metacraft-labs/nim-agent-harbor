## A private, real `ah server start` for a test written in another language
## (a front-end's Playwright suite), over `testing/real_server`: the same
## server, environment and probe tasks the Nim suites use, so the start rules
## are not copied into that language.
##
## Run it, read its first two lines, and talk to it on stdin:
##
##   real_server_cli [--api-key KEY]
##   -> URL http://127.0.0.1:<port>
##   -> KEY <key>                    ("KEY " alone when authentication is off)
##   <- create <prompt>              one probe session (`probeTask`)
##   -> SESSION <id>
##   <- anything else
##   -> ERROR <why>
##
## The server writes its own log to the same stdout (the harness starts it
## with the launcher's streams), so a reader takes only the lines that start
## with `URL `, `KEY `, `SESSION ` or `ERROR ` and skips every other line.
##
## The server is stopped, and its directory removed, when stdin ends. A
## server that cannot start exits 1 with the reason on stderr; no URL line is
## written. `runRealServerCli` is the same over any streams.
##
## Test support, not part of the client: nothing in `nim_agent_harbor`
## imports it. Native only.

import std/[os, osproc, streams, strutils]
import nim_agent_harbor
import ./real_server

proc gitRepo(dir: string) =
  ## An empty git repository on `main`, the probe tasks' workspace.
  createDir(dir)
  if execShellCmd("git init -q -b main " & quoteShell(dir)) != 0 or
     execShellCmd("git -C " & quoteShell(dir) &
       " -c user.name=probe -c user.email=probe@example.invalid" &
       " commit -q --allow-empty -m init") != 0:
    raise newException(IOError, "cannot create the probe repository " & dir)

proc runRealServerCli*(apiKey: string; input, output: Stream;
                       binary = serverBinary()): int =
  ## Serves one server until `input` ends; 0 on a clean stop, 1 when the
  ## server could not start.
  if binary.len == 0:
    stderr.writeLine "real_server_cli: no Agent Harbor server binary: `ah` " &
      "is not on PATH and AH_SERVER_BIN is unset"
    return 1
  var server: RealServer
  try:
    server = startServer(binary, apiKey)
  except CatchableError as error:
    stderr.writeLine "real_server_cli: " & error.msg
    return 1
  defer: server.stop()
  output.writeLine "URL " & server.baseUrl
  output.writeLine "KEY " & apiKey
  output.flush()
  let client = newHarborClient(server.baseUrl, nativeTransport(),
    if apiKey.len > 0: apiKeyAuth(apiKey) else: HarborAuth(kind: akNone))
  let repo = server.root / "repo"
  var line = ""
  while input.readLine(line):
    let command = line.strip
    if command.len == 0: continue
    try:
      if command.startsWith("create "):
        if not dirExists(repo): gitRepo(repo)
        let created = client.createTask(probeTask(repo, command["create ".len .. ^1]))
        if created.sessionIds.len == 0:
          raise newException(HarborError, "the server created no session")
        output.writeLine "SESSION " & created.sessionIds[0]
      else:
        output.writeLine "ERROR unknown command: " & command
    except CatchableError as error:
      output.writeLine "ERROR " & error.msg.replace("\n", " ")
    output.flush()
  0

when isMainModule:
  var apiKey = ""
  var i = 1
  while i <= paramCount():
    if paramStr(i) == "--api-key" and i < paramCount():
      apiKey = paramStr(i + 1)
      inc i
    inc i
  quit runRealServerCli(apiKey, newFileStream(stdin), newFileStream(stdout))
