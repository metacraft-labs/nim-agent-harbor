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
## it does not start a daemon.
##
## Native, and JavaScript under Node. A desktop front-end's main process
## (Electron's) is JavaScript on Node, so it finds the daemon with this same
## module: the rule takes the OS as a value (`daemonPidFilePathFor`), which a
## JavaScript build learns at run time from `process.platform`, and the file
## is read with Node's `fs`. In a browser, where there is no file to read,
## `findLocalServer` answers not found with the reason.

import std/[json, strutils]
when not defined(js):
  import std/os

type
  EnvLookup* = proc(name: string): string {.closure.}
    ## Reads one environment variable ("" when unset). Passed in so a caller
    ## (or a test) decides which environment is consulted.

  DaemonHostOs* = enum
    ## The OS whose rule says where the PID file is.
    dhLinux = "linux"      ## and every other Unix but macOS
    dhMacos = "macos"
    dhWindows = "windows"

  LocalServer* = object
    found*: bool
    baseUrl*: string  ## `http://host:port`, "" when not found
    pidFile*: string  ## the PID file consulted, "" when there was none
    reason*: string   ## why nothing was found, "" when found

when defined(js):
  proc nodeEnv(name: cstring): cstring {.importjs: """
    ((n) => (typeof process === 'object' && process.env &&
             typeof process.env[n] === 'string') ? process.env[n] : '')(#)""".}
  proc nodePlatform(): cstring {.importjs: """
    ((typeof process === 'object' && process.platform) ? process.platform : '')@""".}
  proc nodeHasFs(): bool {.importjs: "(typeof require === 'function')@".}
  proc nodeFileExists(path: cstring): bool {.importjs:
    "require('fs').existsSync(#)".}
  proc nodeReadFile(path: cstring): cstring {.importjs:
    "require('fs').readFileSync(#, 'utf8')".}

proc processEnv*(): EnvLookup =
  ## The process environment (Node's `process.env` in a JavaScript build).
  when defined(js):
    result = proc(name: string): string = $nodeEnv(cstring name)
  else:
    result = proc(name: string): string = getEnv(name)

proc thisHostOs*(): DaemonHostOs =
  ## The OS this process runs on: known when compiled natively, asked of
  ## Node (`process.platform`) in a JavaScript build.
  when defined(js):
    case $nodePlatform()
    of "darwin": dhMacos
    of "win32": dhWindows
    else: dhLinux
  elif defined(windows): dhWindows
  elif defined(macosx): dhMacos
  else: dhLinux

proc joinFor(os: DaemonHostOs; parts: varargs[string]): string =
  ## `parts` joined with `os`'s separator, without doubling one a part
  ## already ends with.
  let sep = if os == dhWindows: '\\' else: '/'
  for part in parts:
    if result.len == 0:
      result = part
    else:
      while result.len > 1 and result[^1] in {'/', sep}:
        result.setLen(result.len - 1)
      result.add sep
      result.add part

proc daemonPidFilePathFor*(os: DaemonHostOs; env: EnvLookup): string =
  ## Where the daemon's PID file is on `os` for this environment, "" when the
  ## environment names no home directory to look in.
  let ahHome = env("AH_HOME")
  if ahHome.len > 0:
    return joinFor(os, ahHome, "server.pid")
  case os
  of dhWindows:
    let local = env("LOCALAPPDATA")
    if local.len > 0: return joinFor(os, local, "agent-harbor", "server.pid")
    ""
  of dhMacos:
    let home = env("HOME")
    if home.len > 0:
      return joinFor(os, home, "Library", "Application Support", "agent-harbor",
                     "server.pid")
    ""
  of dhLinux:
    let state = env("XDG_STATE_HOME")
    if state.len > 0: return joinFor(os, state, "agent-harbor", "server.pid")
    let home = env("HOME")
    if home.len > 0:
      return joinFor(os, home, ".local", "state", "agent-harbor", "server.pid")
    ""

proc daemonPidFilePath*(env: EnvLookup = processEnv()): string =
  ## Where the daemon's PID file is on this OS for this environment, "" when
  ## the environment names no home directory to look in.
  daemonPidFilePathFor(thisHostOs(), env)

proc notFound(reason: string; pidFile = ""): LocalServer =
  LocalServer(found: false, pidFile: pidFile, reason: reason)

proc parseDaemonPidFile*(text: string; pidFile = ""): LocalServer =
  ## The endpoint a PID file's text names. A text that is not a JSON object
  ## with a `rest` object holding a non-empty string `host` and an integer
  ## `port` in 1..65535 is not found, with the reason.
  var node: JsonNode
  try:
    node = parseJson(text)
  except:
    # A bare `except`: on the JavaScript backend `parseJson` throws the
    # engine's own `SyntaxError`, which no Nim exception type catches (as
    # `client.parseBodyOrRaise` notes).
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
  ## The local daemon's REST endpoint, read from its PID file. In a
  ## JavaScript build the file is read with Node's `fs`.
  let path = daemonPidFilePath(env)
  if path.len == 0:
    return notFound("no home directory to find the Agent Harbor daemon in")
  var text: string
  when defined(js):
    if not nodeHasFs():
      return notFound("no file system to find the Agent Harbor daemon in " &
        "(not a Node process)", path)
    var exists = false
    var readError = ""
    try:
      exists = nodeFileExists(cstring path)
      if exists: text = $nodeReadFile(cstring path)
    except:
      # Node's own errors (EACCES, EISDIR) are JavaScript exceptions, which
      # no Nim exception type catches.
      readError = "the file could not be read"
    if readError.len > 0:
      return notFound("cannot read " & path & ": " & readError, path)
    if not exists:
      return notFound("no Agent Harbor daemon has published " & path, path)
  else:
    if not fileExists(path):
      return notFound("no Agent Harbor daemon has published " & path, path)
    try:
      text = readFile(path)
    except CatchableError as error:
      return notFound("cannot read " & path & ": " & error.msg, path)
  parseDaemonPidFile(text, path)
