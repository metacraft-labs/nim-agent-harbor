## How a test starts a private, real `ah server start`: its environment, its
## arguments and a task it accepts without running a model. One description
## for both harnesses, the native one (`testing/real_server`) and the Node
## one (`testing/real_server_node`), so they start the same server.
##
## Test support, not part of the client: nothing in `nim_agent_harbor`
## imports it. Pure: native and JavaScript.

import std/[json, strutils]
import nim_agent_harbor/types

const
  ServerHost* = "127.0.0.1"
    ## The server listens on loopback only.
  IsolatedDirs* = ["XDG_RUNTIME_DIR", "XDG_STATE_HOME", "XDG_CONFIG_HOME",
                   "XDG_DATA_HOME", "XDG_CACHE_HOME"]
    ## The base directories moved under the server's own root, with `HOME`,
    ## so it never sees the operator's configuration, sessions or
    ## credentials.

proc serverEnv*(root, path, apiKey: string; port: int): seq[(string, string)] =
  ## The server's whole environment: `PATH` (to find the tools it runs),
  ## `HOME` and the XDG bases under `root`, its REST address, and its API
  ## key when `apiKey` is not empty (REST authentication is then on).
  result = @[("PATH", path), ("HOME", root)]
  for name in IsolatedDirs:
    result.add (name, root & "/" & name.toLowerAscii())
  if apiKey.len > 0:
    result.add ("AH_API_KEY", apiKey)
  result.add ("AH_REST_HOST", ServerHost)
  result.add ("AH_REST_PORT", $port)

proc serverArgs*(root: string): seq[string] =
  ## The arguments after the binary. `--task-manager-sock` places the
  ## task-manager socket explicitly: without it the server derives the path
  ## from XDG_RUNTIME_DIR and refuses any base whose ancestors are not owned
  ## by root or the current user, which is the case inside user-namespace
  ## sandboxes. `--acp-agent-cmd true` satisfies the requirement for at
  ## least one ACP agent; no agent is ever started.
  @["server", "start",
    "--acp-uds", root & "/acp.sock",
    "--task-manager-sock", root & "/tm.sock",
    "--acp-agent-cmd", "true"]

proc serverBaseUrl*(port: int): string =
  "http://" & ServerHost & ":" & $port

proc probeTask*(repoDir, prompt: string): CreateTaskRequest =
  ## A task the server accepts without running a model: an ACP agent whose
  ## launch command is `true`. The session it creates fails at workspace
  ## preparation or agent start, which is enough to produce its lifecycle.
  CreateTaskRequest(
    prompt: prompt,
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
