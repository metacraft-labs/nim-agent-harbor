## Finding the local Agent Harbor daemon from a Node process: the JavaScript
## build of `nim_agent_harbor/discovery`, as a desktop front-end's main
## process (Electron's, Node) runs it.
##
## The rule for where the PID file is depends on the OS the process runs on,
## and a JavaScript build learns that at run time (`process.platform`), not at
## compile time, so the rule takes the OS as a value: every OS's answer is
## checked here, whichever OS runs the test, macOS's
## `~/Library/Application Support` among them.
##
## No mocks: the file cases write real files with Node's `fs` under a fresh
## directory in the OS temp directory, and read them back through
## `findLocalServer`. The environment is passed as a lookup procedure, so a
## case never changes the process environment. The PID file texts have the
## shape a real daemon writes (its keys were read from a running daemon, its
## values are invented here).
##
## Run with `nim js -r` (Node); `tools/nim-js-test-gate.sh` in `just test-js`.

when not defined(js):
  {.error: "test_discovery_node is the JavaScript (Node) build's test".}

import std/[strutils, tables, unittest]
import nim_agent_harbor/discovery

const realShape = """{
  "pid": 4242, "version": "0.6.17", "channel": "release",
  "rest": {"host": "127.0.0.1", "port": 38117},
  "control_sock": "/run/user/1000/agentharbor/daemon.sock"
}"""

proc lookup(vars: openArray[(string, string)]): EnvLookup =
  let table = vars.toTable
  result = proc(name: string): string = table.getOrDefault(name, "")

proc makeTempDir(): cstring {.importjs: """
  (() => { const fs = require('fs'), os = require('os'), path = require('path');
           return fs.mkdtempSync(path.join(os.tmpdir(), 'ahdisc-')); })()@""".}
proc writeText(path, text: cstring) {.importjs: "require('fs').writeFileSync(#, #)".}
proc removeTree(path: cstring) {.importjs:
  "require('fs').rmSync(#, {recursive: true, force: true})".}
proc joinPath(a, b: cstring): cstring {.importjs: "require('path').join(#, #)".}
proc nodePlatform(): cstring {.importjs: "(process.platform)@".}

suite "where the PID file is, on every OS (the JavaScript build)":
  test "AH_HOME wins on every OS":
    for os in DaemonHostOs:
      let path = daemonPidFilePathFor(os, lookup({"AH_HOME": "/srv/ah",
        "HOME": "/home/u", "XDG_STATE_HOME": "/x", "LOCALAPPDATA": "C:\\L"}))
      check path.startsWith("/srv/ah")
      check path.endsWith("server.pid")

  test "macOS: ~/Library/Application Support":
    check daemonPidFilePathFor(dhMacos, lookup({"HOME": "/Users/u",
      "XDG_STATE_HOME": "/x"})) ==
      "/Users/u/Library/Application Support/agent-harbor/server.pid"

  test "Linux: the XDG state directory, else ~/.local/state":
    check daemonPidFilePathFor(dhLinux, lookup({"XDG_STATE_HOME": "/x",
      "HOME": "/home/u"})) == "/x/agent-harbor/server.pid"
    check daemonPidFilePathFor(dhLinux, lookup({"HOME": "/home/u"})) ==
      "/home/u/.local/state/agent-harbor/server.pid"

  test "Windows: %LOCALAPPDATA%":
    check daemonPidFilePathFor(dhWindows, lookup({"LOCALAPPDATA": "C:\\Users\\u\\AppData\\Local",
      "HOME": "/home/u"})) ==
      "C:\\Users\\u\\AppData\\Local\\agent-harbor\\server.pid"

  test "no home and no override: no path, on every OS":
    for os in DaemonHostOs:
      check daemonPidFilePathFor(os, lookup(newSeq[(string, string)]())) == ""

  test "the OS is the one Node reports":
    let expected = case $nodePlatform()
                   of "darwin": dhMacos
                   of "win32": dhWindows
                   else: dhLinux
    check thisHostOs() == expected

suite "finding the local server from Node":
  test "a published PID file is found":
    let dir = makeTempDir()
    defer: removeTree(dir)
    let file = joinPath(dir, "server.pid")
    writeText(file, realShape)
    let server = findLocalServer(lookup({"AH_HOME": $dir}))
    check server.found
    check server.baseUrl == "http://127.0.0.1:38117"
    check server.pidFile == $file

  test "no PID file: not found, and the reason names the path":
    let dir = makeTempDir()
    defer: removeTree(dir)
    let server = findLocalServer(lookup({"AH_HOME": $dir}))
    check not server.found
    check server.baseUrl == ""
    check $joinPath(dir, "server.pid") in server.reason

  test "an unreadable PID file is not found, and says why":
    let dir = makeTempDir()
    defer: removeTree(dir)
    writeText(joinPath(dir, "server.pid"), "{")
    let server = findLocalServer(lookup({"AH_HOME": $dir}))
    check not server.found
    check server.reason.len > 0

  test "no home at all: not found, with the reason":
    let server = findLocalServer(lookup(newSeq[(string, string)]()))
    check not server.found
    check server.reason.len > 0

  test "the process environment is Node's":
    # `processEnv` reads `process.env`: PATH is set in every Node process.
    check processEnv()("PATH").len > 0
    check processEnv()("AH_DISCOVERY_TEST_SURELY_UNSET_VARIABLE") == ""
