## The real-server launcher (`nim_agent_harbor/testing/real_server_cli`), the
## private server a test in another language starts (a front-end's
## Playwright suite): it prints the server's address and key, creates probe
## sessions on request, and stops the server when its input ends.
##
## No mocks: the launcher is compiled and run as a separate process here,
## exactly as such a suite runs it, against the installed `ah` (or
## `AH_SERVER_BIN`); the sessions it reports are read back from the server
## through the client. Without a server binary the suite fails: a skipped
## suite here would read as a pass.

import std/[json, os, osproc, streams, strutils, unittest]
import nim_agent_harbor
import nim_agent_harbor/testing/real_server

const
  SelfSource = currentSourcePath()
  CompilerAtBuild = getCurrentCompilerExe()

let
  root = SelfSource.parentDir.parentDir
  nimExe = if fileExists(CompilerAtBuild): CompilerAtBuild else: findExe("nim")
  workDir = getTempDir() / ("nah-real-server-cli-" & $getCurrentProcessId())

proc compileCli(): string =
  createDir(workDir)
  result = workDir / "real_server_cli"
  let p = startProcess(nimExe, workingDir = root, options = {poStdErrToStdOut},
    args = @["c", "--hints:off", "--warnings:off", "--path:src",
             "--path:../nim-everywhere/src",
             "--nimcache:" & (workDir / "nimcache"), "-o:" & result,
             "src/nim_agent_harbor/testing/real_server_cli.nim"])
  let output = p.outputStream.readAll()
  if p.waitForExit() != 0 or not fileExists(result):
    echo output
    result = ""
  p.close()

proc readLineOf(p: Process): string =
  ## The launcher's next protocol line on stdout ("" at its end); the
  ## server's own log lines, on the same stream, are skipped.
  var line = ""
  while p.outputStream.readLine(line):
    for word in ["URL ", "KEY ", "SESSION ", "ERROR "]:
      if line.startsWith(word): return line
  ""

suite "the real-server launcher":
  test "it serves a private server, creates sessions on request, and stops at the end of its input":
    let binary = serverBinary()
    check binary.len > 0
    if binary.len > 0:
      let cli = compileCli()
      check cli.len > 0
      if cli.len > 0:
        let p = startProcess(cli, args = ["--api-key", "cli-test-key"],
                             options = {})
        let url = p.readLineOf
        let key = p.readLineOf
        check url.startsWith("URL http://127.0.0.1:")
        check key == "KEY cli-test-key"
        let baseUrl = url["URL ".len .. ^1]
        let client = newHarborClient(baseUrl, nativeTransport(),
                                     apiKeyAuth("cli-test-key"))
        check client.listSessions().items.len == 0
        p.inputStream.write("create Fix the uploader\n")
        p.inputStream.flush()
        let created = p.readLineOf
        check created.startsWith("SESSION ")
        let id = created["SESSION ".len .. ^1]
        let listed = client.listSessions().items
        check listed.len == 1 and listed[0]["id"].getStr == id
        p.inputStream.write("nonsense\n")
        p.inputStream.flush()
        check p.readLineOf.startsWith("ERROR ")
        p.inputStream.close()
        check p.waitForExit(30_000) == 0
        p.close()
        var stopped = false
        try:
          discard client.listSessions()
        except CatchableError:
          stopped = true
        check stopped
  removeDir(workDir)
