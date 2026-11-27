## Starts a private, real `ah server start` from a Node process, for tests of
## a client that runs on Node: a desktop app's main process, which follows
## the server for its windows. The Node twin of `testing/real_server`: the
## same server, started with the same environment and arguments
## (`testing/server_launch`), in a fresh directory under `/tmp` that is also
## its `HOME` and XDG base, on a loopback port.
##
## Test support, not part of the client: nothing in `nim_agent_harbor`
## imports it. JavaScript on Node only (`child_process`, `fs`, `net`,
## `fetch`).

when not defined(js):
  {.error: "nim_agent_harbor/testing/real_server_node runs on Node; native tests use testing/real_server".}

import std/asyncjs
import ./server_launch

export server_launch

type
  NodeServer* = object
    root*: string
    baseUrl*: string
    pid*: int
    child: JsChild

  JsChild = ref object  ## Node's ChildProcess

proc nodeEnv(name: cstring): cstring {.importjs:
  "(process.env[#] || '')".}
proc whichOnPath(name: cstring): cstring {.importjs: """
  ((name) => {
    const fs = require('fs'), path = require('path');
    for (const dir of (process.env.PATH || '').split(path.delimiter)) {
      if (!dir) continue;
      const candidate = path.join(dir, name);
      try { fs.accessSync(candidate, fs.constants.X_OK); return candidate; }
      catch (e) {}
    }
    return '';
  })(#)""".}
proc makeShortTempDir(): cstring {.importjs:
  "require('fs').mkdtempSync('/tmp/ahk')@".}
proc removeTree(path: cstring) {.importjs:
  "require('fs').rmSync(#, {recursive: true, force: true})".}
proc freePortRaw(): Future[int] {.importjs: """
  new Promise((resolve, reject) => {
    const server = require('net').createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      server.close(() => resolve(port));
    });
  })@""".}
proc spawnServer(binary, cwd: cstring; args, names, values: seq[cstring]): JsChild {.importjs: """
  ((binary, cwd, args, names, values) => {
    const env = {};
    names.forEach((n, i) => { env[n] = values[i]; });
    const child = require('child_process').spawn(binary, args,
      {cwd, env, stdio: ['ignore', 'inherit', 'inherit']});
    child.__exited = false;
    child.__exitCode = null;
    child.on('exit', (code, signal) => {
      child.__exited = true;
      child.__exitCode = code === null ? String(signal) : String(code);
    });
    child.on('error', (e) => { child.__exited = true; child.__exitCode = String(e.message); });
    return child;
  })(#, #, #, #, #)""".}
proc childPid(child: JsChild): int {.importjs: "(#.pid || 0)".}
proc childExited(child: JsChild): bool {.importjs: "#.__exited".}
proc childExitCode(child: JsChild): cstring {.importjs: "String(#.__exitCode)".}
proc signalChild(child: JsChild; signal: cstring) {.importjs:
  "((c, s) => { try { c.kill(s); } catch (e) {} })(#, #)".}
proc healthy(url: cstring): Future[bool] {.importjs:
  "fetch(#).then(r => r.status === 200, () => false)".}
proc sleepMs(ms: int): Future[void] {.importjs:
  "new Promise((resolve) => setTimeout(resolve, #))".}
proc nowMs(): float {.importjs: "performance.now()@".}

proc serverBinaryNode*(): string =
  ## The server to start, or "" when none is installed: `AH_SERVER_BIN`,
  ## else `ah` on `PATH`.
  result = $nodeEnv("AH_SERVER_BIN")
  if result.len == 0:
    result = $whichOnPath("ah")

proc freePortNode*(): Future[int] =
  ## A loopback port no one listens on at the moment of the call.
  freePortRaw()

proc stopNode*(server: NodeServer): Future[void] {.async.} =
  ## Stops the server (SIGTERM, then SIGKILL after 10 s) and removes its
  ## directory.
  if not server.child.isNil and not server.child.childExited:
    server.child.signalChild("SIGTERM")
    let deadline = nowMs() + 10_000
    while not server.child.childExited and nowMs() < deadline:
      await sleepMs(50)
    if not server.child.childExited:
      server.child.signalChild("SIGKILL")
      while not server.child.childExited:
        await sleepMs(50)
  if server.root.len > 0:
    removeTree(cstring server.root)

proc startServerNode*(binary: string; apiKey = ""; port = 0): Future[NodeServer] {.async.} =
  ## Starts the server and waits for `/healthz`. A non-empty `apiKey` turns
  ## REST authentication on. `port` 0 picks a free one. A server that fails
  ## to start or come up within 60 s is stopped, its directory removed, and
  ## the failure raised.
  var server: NodeServer
  # Unix socket paths must fit in SUN_LEN (108 bytes), so the server's state
  # lives under a short directory rather than the (often long) temp dir.
  server.root = $makeShortTempDir()
  let chosen = if port == 0: await freePortNode() else: port
  server.baseUrl = serverBaseUrl(chosen)
  var names, values, args: seq[cstring]
  for (name, value) in serverEnv(server.root, $nodeEnv("PATH"), apiKey, chosen):
    names.add cstring(name)
    values.add cstring(value)
  for arg in serverArgs(server.root): args.add cstring(arg)
  server.child = spawnServer(cstring binary, cstring server.root, args, names, values)
  server.pid = server.child.childPid
  let deadline = nowMs() + 60_000
  var failure = ""
  while true:
    if server.child.childExited:
      failure = "ah server exited with " & $server.child.childExitCode &
        " before answering /healthz"
      break
    if await healthy(cstring(server.baseUrl & "/healthz")):
      return server
    if nowMs() > deadline:
      failure = "ah server did not answer /healthz within 60s"
      break
    await sleepMs(250)
  await stopNode(server)
  raise newException(IOError, failure)
