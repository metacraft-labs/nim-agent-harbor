## Finding the local Agent Harbor daemon's REST endpoint from the PID file
## the daemon publishes.
##
## No mocks: the cases write real files under a fresh temporary directory
## and read them back through `findLocalServer`; the environment is passed
## as a lookup procedure so a case never changes the process environment.
## The PID file texts have the shape a real daemon writes (its keys were
## read from a running daemon, its values are invented here).

import std/[os, strutils, tables, tempfiles, unittest]
import nim_agent_harbor/discovery

const realShape = """{
  "pid": 4242, "version": "0.6.17", "channel": "release",
  "started_at": "2026-11-27T05:00:00Z",
  "rest": {"host": "127.0.0.1", "port": 38117},
  "control_sock": "/run/user/1000/agentharbor/daemon.sock",
  "task_manager_sock": "/run/user/1000/ah/task-manager.sock",
  "acp_sock": "/run/user/1000/agentharbor/acp.sock"
}"""

proc lookup(vars: openArray[(string, string)]): EnvLookup =
  let table = vars.toTable
  result = proc(name: string): string = table.getOrDefault(name, "")

suite "the daemon's PID file":
  test "the endpoint is rest.host and rest.port":
    let server = parseDaemonPidFile(realShape)
    check server.found
    check server.baseUrl == "http://127.0.0.1:38117"
    check server.reason == ""

  test "an IPv6 host is bracketed":
    let server = parseDaemonPidFile("""{"rest": {"host": "::1", "port": 3001}}""")
    check server.found
    check server.baseUrl == "http://[::1]:3001"

  test "a file that names no usable endpoint says why":
    for text in ["not json", "[]", """{"pid": 1}""", """{"rest": {}}""",
                 """{"rest": {"host": "127.0.0.1"}}""",
                 """{"rest": {"host": "", "port": 3001}}""",
                 """{"rest": {"host": "127.0.0.1", "port": 0}}""",
                 """{"rest": {"host": "127.0.0.1", "port": 70000}}""",
                 """{"rest": {"host": "127.0.0.1", "port": "3001"}}"""]:
      let server = parseDaemonPidFile(text)
      check not server.found
      check server.baseUrl == ""
      check server.reason.len > 0

suite "where the PID file is":
  test "AH_HOME wins":
    check daemonPidFilePath(lookup({"AH_HOME": "/srv/ah", "HOME": "/home/u",
      "XDG_STATE_HOME": "/x"})) == "/srv/ah" / "server.pid"

  when defined(linux):
    test "Linux: the XDG state directory, else ~/.local/state":
      check daemonPidFilePath(lookup({"XDG_STATE_HOME": "/x", "HOME": "/home/u"})) ==
        "/x/agent-harbor/server.pid"
      check daemonPidFilePath(lookup({"HOME": "/home/u"})) ==
        "/home/u/.local/state/agent-harbor/server.pid"

  when defined(macosx):
    test "macOS: Application Support":
      check daemonPidFilePath(lookup({"HOME": "/Users/u"})) ==
        "/Users/u/Library/Application Support/agent-harbor/server.pid"

  test "every OS's rule, whichever OS runs the test":
    # The rule takes the OS as a value, so the JavaScript build (which learns
    # the OS at run time) and this one answer from the same rule.
    check daemonPidFilePathFor(dhMacos, lookup({"HOME": "/Users/u",
      "XDG_STATE_HOME": "/x"})) ==
      "/Users/u/Library/Application Support/agent-harbor/server.pid"
    check daemonPidFilePathFor(dhLinux, lookup({"HOME": "/home/u"})) ==
      "/home/u/.local/state/agent-harbor/server.pid"
    check daemonPidFilePathFor(dhWindows, lookup({"LOCALAPPDATA": "C:\\L"})) ==
      "C:\\L\\agent-harbor\\server.pid"
    check daemonPidFilePath(lookup({"HOME": "/h", "LOCALAPPDATA": "C:\\L"})) ==
      daemonPidFilePathFor(thisHostOs(), lookup({"HOME": "/h", "LOCALAPPDATA": "C:\\L"}))

  test "no home and no override: no path":
    when not defined(windows):
      check daemonPidFilePath(lookup(newSeq[(string, string)]())) == ""

suite "finding the local server":
  test "a published PID file is found":
    let dir = createTempDir("ahdisc", "")
    defer: removeDir(dir)
    writeFile(dir / "server.pid", realShape)
    let server = findLocalServer(lookup({"AH_HOME": dir}))
    check server.found
    check server.baseUrl == "http://127.0.0.1:38117"
    check server.pidFile == dir / "server.pid"

  test "no PID file: not found, and the reason names the path":
    let dir = createTempDir("ahdisc", "")
    defer: removeDir(dir)
    let server = findLocalServer(lookup({"AH_HOME": dir}))
    check not server.found
    check (dir / "server.pid") in server.reason

  test "an unreadable PID file is not found":
    let dir = createTempDir("ahdisc", "")
    defer: removeDir(dir)
    writeFile(dir / "server.pid", "{")
    let server = findLocalServer(lookup({"AH_HOME": dir}))
    check not server.found
    check server.reason.len > 0
