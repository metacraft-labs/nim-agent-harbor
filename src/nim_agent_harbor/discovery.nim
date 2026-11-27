## Finds the local Agent Harbor daemon's REST endpoint.
##
## The per-user daemon publishes a JSON PID file when it starts; a front-end
## on the same machine reads its `rest` object (`host`, `port`) to know where
## the daemon's REST API listens. This module reads only that object; the
## file's other fields are the daemon's own business.
##
## Where the file is:
##
## - `$AH_HOME/server.pid` when `AH_HOME` is set (an isolated daemon);
## - otherwise the per-user state directory: on Linux
##   `${XDG_STATE_HOME:-~/.local/state}/agent-harbor/server.pid`, on macOS
##   `~/Library/Application Support/agent-harbor/server.pid`, on Windows
##   `%LOCALAPPDATA%\agent-harbor\server.pid`.
##
## Finding the file does not prove the daemon is running: the file can
## outlive a daemon that crashed. A caller connects and reports the failure;
## it does not start a daemon. Native only.

when defined(js):
  {.error: "nim_agent_harbor/discovery reads a local file; it is native only".}

import std/[json, os, strutils]

type
  EnvLookup* = proc(name: string): string {.closure.}
    ## Reads one environment variable ("" when unset). Passed in so a caller
    ## (or a test) decides which environment is consulted.

  LocalServer* = object
    found*: bool
    baseUrl*: string  ## `http://host:port`, "" when not found
    pidFile*: string  ## the PID file consulted, "" when there was none
    reason*: string   ## why nothing was found, "" when found

proc processEnv*(): EnvLookup =
  ## The process environment.
  result = proc(name: string): string = getEnv(name)

proc daemonPidFilePath*(env: EnvLookup = processEnv()): string =
  ## Where the daemon's PID file is for this environment, "" when the
  ## environment names no home directory to look in.
  let ahHome = env("AH_HOME")
  if ahHome.len > 0:
    return ahHome / "server.pid"
  when defined(windows):
    let local = env("LOCALAPPDATA")
    if local.len > 0: return local / "agent-harbor" / "server.pid"
    ""
  elif defined(macosx):
    let home = env("HOME")
    if home.len > 0:
      return home / "Library" / "Application Support" / "agent-harbor" / "server.pid"
    ""
  else:
    let state = env("XDG_STATE_HOME")
    if state.len > 0: return state / "agent-harbor" / "server.pid"
    let home = env("HOME")
    if home.len > 0: return home / ".local" / "state" / "agent-harbor" / "server.pid"
    ""

proc notFound(reason: string; pidFile = ""): LocalServer =
  LocalServer(found: false, pidFile: pidFile, reason: reason)

proc parseDaemonPidFile*(text: string; pidFile = ""): LocalServer =
  ## The endpoint a PID file's text names. A text that is not a JSON object
  ## with a `rest` object holding a non-empty string `host` and an integer
  ## `port` in 1..65535 is not found, with the reason.
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return notFound("the daemon's PID file is not JSON", pidFile)
  if node.kind != JObject:
    return notFound("the daemon's PID file is not a JSON object", pidFile)
  let rest = node{"rest"}
  if rest.isNil or rest.kind != JObject:
    return notFound("the daemon's PID file names no REST endpoint", pidFile)
  let host = rest{"host"}
  let port = rest{"port"}
  if host.isNil or host.kind != JString or host.getStr.len == 0:
    return notFound("the daemon's PID file names no REST host", pidFile)
  if port.isNil or port.kind != JInt or port.getBiggestInt < 1 or
      port.getBiggestInt > 65535:
    return notFound("the daemon's PID file names no valid REST port", pidFile)
  var h = host.getStr
  if ':' in h and not h.startsWith('['): h = "[" & h & "]"   # an IPv6 address
  LocalServer(found: true, pidFile: pidFile,
    baseUrl: "http://" & h & ":" & $port.getBiggestInt)

proc findLocalServer*(env: EnvLookup = processEnv()): LocalServer =
  ## The local daemon's REST endpoint, read from its PID file.
  let path = daemonPidFilePath(env)
  if path.len == 0:
    return notFound("no home directory to find the Agent Harbor daemon in")
  if not fileExists(path):
    return notFound("no Agent Harbor daemon has published " & path, path)
  var text: string
  try:
    text = readFile(path)
  except CatchableError as error:
    return notFound("cannot read " & path & ": " & error.msg, path)
  parseDaemonPidFile(text, path)
