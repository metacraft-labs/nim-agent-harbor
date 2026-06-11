import std/json
import std/strutils
import unittest
import nim_agent_harbor

suite "nim-agent-harbor":
  test "agent_harbor_client_task_request_roundtrip":
    let client = newHarborClient("http://localhost:18080", fakeHarborTransport(), apiKeyAuth("test"))
    let response = client.createTask(CreateTaskRequest(
      tenantId: "acme",
      projectId: "storefront",
      prompt: "fix tests",
      repo: RepoConfig(mode: "git", url: "git@example.com/repo.git", branch: "main"),
      runtime: defaultRuntime(),
      workspacePath: "/tmp/repo",
      workingCopyMode: "git_worktree",
      executionHostId: "executor-a",
      sandbox: SandboxConfig(
        mode: "static",
        allowNetwork: true,
        blacklistPaths: @["~/.ssh"],
        limits: SandboxLimits(pidsMax: 2048, memoryMax: "4G")),
      delivery: DeliveryConfig(mode: "pr", targetBranch: "main"),
      agents: @[AgentConfig(
        agent: AgentSoftware(software: "acp", version: "latest"),
        model: "mock",
        count: 1,
        settings: %*{"maxTokens": 8000},
        acpStdioLaunchCommand: AcpStdioLaunchCommand(binary: "mock-agent", args: @["--scenario", "turn.json"]))],
      output: defaultOutput(),
      llmProvider: LlmProviderConfig(apiStyle: "openai", baseUrl: "https://api.openai.com/v1", model: "gpt-5"),
      labels: %*{"priority": "p2"}))
    check response.taskId == "task-1"
    check response.sessionIds == @["session-1"]
    check response.links.events.endsWith("/events")

    let camelResponse = taskResponseFromJson(%*{
      "taskId": "task-camel",
      "sessionIds": ["session-camel"],
      "status": "queued"
    })
    check camelResponse.taskId == "task-camel"
    check camelResponse.sessionIds == @["session-camel"]

    let wrappedResponse = taskResponseFromJson(%(
      "{\"task_id\":\"task-wrapped\",\"session_ids\":[\"session-wrapped\"],\"status\":\"queued\"}"))
    check wrappedResponse.taskId == "task-wrapped"
    check wrappedResponse.sessionIds == @["session-wrapped"]

    let accepted = client.sendPrompt("session-1", @[harborTextBlock("continue")])
    check accepted.accepted
    check accepted.sessionId == "session-1"

  test "task request serializes workspace sandbox delivery and agent settings":
    let node = taskToJson(CreateTaskRequest(
      prompt: "fix tests",
      repo: RepoConfig(mode: "git", url: "git@example.com/repo.git", branch: "main"),
      runtime: defaultRuntime(),
      workspacePath: "/tmp/repo",
      workingCopyMode: "git_worktree",
      executionHostId: "executor-a",
      sandbox: defaultSandbox(),
      delivery: DeliveryConfig(mode: "branch", targetBranch: "main"),
      agents: @[AgentConfig(
        agent: AgentSoftware(software: "acp", version: "latest"),
        model: "mock",
        count: 1,
        settings: %*{"temperature": 0},
        acpStdioLaunchCommand: AcpStdioLaunchCommand(binary: "mock-agent", args: @["--stdio"]))],
      output: defaultOutput(),
      labels: newJObject()))
    check node["prompt"].getStr() == "fix tests"
    check node["workspace_path"].getStr() == "/tmp/repo"
    check node["working_copy_mode"].getStr() == "git_worktree"
    check node["workspace"]["executionHostId"].getStr() == "executor-a"
    check node["sandbox"]["debug"].getBool()
    check node["sandbox"]["mode"].getStr() == "dynamic"
    check not node["sandbox"].hasKey("tmpfs-size")
    check not node["sandbox"].hasKey("limits")
    check not node["sandbox"].hasKey("allow-network")
    check node["delivery"]["mode"].getStr() == "branch"
    check node["agents"][0]["type"].getStr() == "acp"
    check node["agents"][0]["version"].getStr() == "latest"
    check node["agents"][0]["settings"]["model"].getStr() == "mock"
    check node["agents"][0]["settings"]["temperature"].getInt() == 0
    check node["agents"][0]["acpStdioLaunchCommand"]["binary"].getStr() == "mock-agent"

  test "reads and subscribes to session events endpoint":
    let client = newHarborClient("http://localhost:18080", fakeHarborTransport())
    let events = client.readSessionEvents("session-1", EventsQuery(types: @["workspace", "thought"], sort: "asc"))
    check events.len == 5
    check events[0].kind == hekWorkspace
    check events[0].status == "provisioning"
    check events[1].mountPath == "/tmp/ah-workspace"
    check events[2].kind == hekThought
    check events[3].kind == hekToolUse
    check events[3].toolExecutionId == "tool-1"
    check events[4].kind == hekDelivery
    check events[4].deliveryMode == "pr"

    var seen: seq[HarborEventKind] = @[]
    client.subscribeSessionEvents("session-1", proc(event: HarborEvent) =
      seen.add event.kind)
    check seen == @[hekWorkspace, hekWorkspace, hekThought, hekToolUse, hekDelivery]

  test "reads paginated event history":
    let client = newHarborClient("http://localhost:18080", fakeHarborTransport())
    let history = client.readEventHistory("session-1", EventHistoryQuery(limit: 2))
    check history.events.len == 2
    check history.events[0].kind == hekFileEdit
    check history.events[0].filePath == "src/app.nim"
    check history.events[1].kind == hekToolResult
    check history.oldestTimestamp == 1714300002

    let wrappedHistory = eventHistoryFromJson(%(
      "{\"events\":[{\"type\":\"diff\",\"file_path\":\"src/app.nim\"}],\"has_more\":false,\"total_count\":1}"))
    check wrappedHistory.events.len == 1
    check wrappedHistory.events[0].kind == hekDiff
    check wrappedHistory.events[0].filePath == "src/app.nim"
    check wrappedHistory.totalCount == 1

    let arrayHistory = eventHistoryFromJson(%*[
      {"type": "workspace", "mountPath": "/tmp/agent"}
    ])
    check arrayHistory.events.len == 1
    check arrayHistory.events[0].kind == hekWorkspace

  test "SSE data lines parse as typed events":
    let events = parseSseEvents("event: message\ndata: {\"type\":\"log\",\"message\":\"Running tests\",\"ts\":\"now\"}\n\n")
    check events.len == 1
    check events[0].kind == hekLog
    check events[0].message == "Running tests"

  test "harbor content blocks are owned by Harbor":
    let item = contentBlockFromJson(%*{"type": "resource", "uri": "file:///tmp/repo", "mimeType": "text/plain"})
    check item.kind == hcbResource
    check item.uri == "file:///tmp/repo"
    check contentBlockToJson(harborTextBlock("owned"))["text"].getStr() == "owned"
