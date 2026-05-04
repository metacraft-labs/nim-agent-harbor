import std/json

type
  HarborError* = object of CatchableError
  HarborContentBlockKind* = enum
    hcbText = "text"
    hcbImage = "image"
    hcbAudio = "audio"
    hcbResource = "resource"
  HarborContentBlock* = object
    kind*: HarborContentBlockKind
    text*: string
    uri*: string
    mimeType*: string
    data*: string
  AuthKind* = enum
    akNone
    akApiKey
    akBearer
  HarborAuth* = object
    kind*: AuthKind
    token*: string
  RepoConfig* = object
    mode*: string
    url*: string
    branch*: string
    commit*: string
  RuntimeConfig* = object
    kind*: string
    devcontainerPath*: string
    cpu*: int
    memoryMiB*: int
  WorkspaceConfig* = object
    snapshotPreference*: seq[string]
    executionHostId*: string
    workingCopyMode*: string
  SandboxLimits* = object
    pidsMax*: int
    memoryMax*: string
    memoryHigh*: string
    cpuMax*: string
    ioMax*: string
  SandboxConfig* = object
    mode*: string
    allowNetwork*: bool
    containers*: bool
    vm*: bool
    allowKvm*: bool
    debug*: bool
    rwPaths*: seq[string]
    overlayPaths*: seq[string]
    blacklistPaths*: seq[string]
    tmpfsSize*: string
    limits*: SandboxLimits
  DeliveryConfig* = object
    mode*: string
    targetBranch*: string
  AcpStdioLaunchCommand* = object
    binary*: string
    args*: seq[string]
  AgentSoftware* = object
    software*: string
    version*: string
  AgentConfig* = object
    agent*: AgentSoftware
    model*: string
    count*: int
    displayName*: string
    settings*: JsonNode
    acpStdioLaunchCommand*: AcpStdioLaunchCommand
  OutputConfig* = object
    format*: string
    flavor*: string
    nonInteractive*: bool
  LlmProviderConfig* = object
    apiStyle*: string
    baseUrl*: string
    apiKey*: string
    model*: string
  CreateTaskRequest* = object
    tenantId*: string
    projectId*: string
    prompt*: seq[HarborContentBlock]
    repo*: RepoConfig
    runtime*: RuntimeConfig
    workspace*: WorkspaceConfig
    sandbox*: SandboxConfig
    delivery*: DeliveryConfig
    agents*: seq[AgentConfig]
    output*: OutputConfig
    llmProvider*: LlmProviderConfig
    labels*: JsonNode
  LinkSet* = object
    self*: string
    events*: string
    logs*: string
  CreateTaskResponse* = object
    taskId*: string
    sessionIds*: seq[string]
    status*: string
    links*: LinkSet
  PromptAcceptedResponse* = object
    sessionId*: string
    accepted*: bool
    ts*: string
  HarborEventKind* = enum
    hekLog = "log"
    hekThought = "thought"
    hekToolUse = "tool_use"
    hekToolResult = "tool_result"
    hekFileEdit = "file_edit"
    hekDiff = "diff"
    hekWorkspace = "workspace"
    hekDelivery = "delivery"
    hekLlmRequest = "llm_request"
    hekSubAgent = "sub_agent"
    hekStatus = "status"
    hekUnknown = "unknown"
  HarborEvent* = object
    kind*: HarborEventKind
    message*: string
    status*: string
    level*: string
    toolName*: string
    toolExecutionId*: string
    filePath*: string
    linesAdded*: int
    linesRemoved*: int
    mountPath*: string
    provider*: string
    workingCopyMode*: string
    deliveryMode*: string
    deliveryUrl*: string
    ts*: string
    timestamp*: int64
    raw*: JsonNode
  EventsQuery* = object
    types*: seq[string]
    level*: string
    since*: string
    until*: string
    page*: int
    perPage*: int
    sort*: string
  EventHistoryQuery* = object
    limit*: int
    before*: int64
  EventHistoryResponse* = object
    events*: seq[HarborEvent]
    hasMore*: bool
    oldestTimestamp*: int64
    totalCount*: int

proc apiKeyAuth*(token: string): HarborAuth =
  HarborAuth(kind: akApiKey, token: token)

proc bearerAuth*(token: string): HarborAuth =
  HarborAuth(kind: akBearer, token: token)

proc defaultOutput*(): OutputConfig =
  OutputConfig(format: "text", flavor: "native", nonInteractive: false)

proc defaultRuntime*(): RuntimeConfig =
  RuntimeConfig(kind: "local", cpu: 0, memoryMiB: 0)

proc defaultAgent*(software = "acp"; model = "default"): AgentConfig =
  AgentConfig(agent: AgentSoftware(software: software, version: "latest"),
    model: model, count: 1, settings: newJObject())

proc defaultWorkspace*(): WorkspaceConfig =
  WorkspaceConfig(snapshotPreference: @["zfs", "btrfs", "overlay", "copy"])

proc defaultSandbox*(): SandboxConfig =
  SandboxConfig(mode: "dynamic", debug: true)

proc defaultDelivery*(): DeliveryConfig =
  DeliveryConfig(mode: "patch")

proc harborTextBlock*(text: string): HarborContentBlock =
  HarborContentBlock(kind: hcbText, text: text)

proc harborImageBlock*(uri: string; mimeType = ""): HarborContentBlock =
  HarborContentBlock(kind: hcbImage, uri: uri, mimeType: mimeType)

proc harborAudioBlock*(uri: string; mimeType = ""): HarborContentBlock =
  HarborContentBlock(kind: hcbAudio, uri: uri, mimeType: mimeType)

proc harborResourceBlock*(uri: string; mimeType = ""): HarborContentBlock =
  HarborContentBlock(kind: hcbResource, uri: uri, mimeType: mimeType)

proc `$`*(kind: HarborContentBlockKind): string =
  case kind
  of hcbText: "text"
  of hcbImage: "image"
  of hcbAudio: "audio"
  of hcbResource: "resource"

proc contentBlockToJson*(item: HarborContentBlock): JsonNode =
  result = %*{"type": $item.kind}
  case item.kind
  of hcbText:
    result["text"] = %item.text
  of hcbImage, hcbAudio, hcbResource:
    if item.uri.len > 0: result["uri"] = %item.uri
    if item.mimeType.len > 0: result["mimeType"] = %item.mimeType
    if item.data.len > 0: result["data"] = %item.data

proc contentBlockFromJson*(node: JsonNode): HarborContentBlock =
  let kind = node{"type"}.getStr("text")
  case kind
  of "image": result.kind = hcbImage
  of "audio": result.kind = hcbAudio
  of "resource", "resource_link": result.kind = hcbResource
  else: result.kind = hcbText
  result.text = node{"text"}.getStr("")
  result.uri = node{"uri"}.getStr("")
  result.mimeType = node{"mimeType"}.getStr("")
  result.data = node{"data"}.getStr("")

proc taskToJson*(req: CreateTaskRequest): JsonNode =
  var prompt = newJArray()
  for item in req.prompt:
    prompt.add contentBlockToJson(item)
  var agents = newJArray()
  for agent in req.agents:
    var agentNode = %*{
      "agent": {"software": agent.agent.software, "version": agent.agent.version},
      "model": agent.model,
      "count": agent.count,
      "settings": agent.settings
    }
    if agent.displayName.len > 0:
      agentNode["displayName"] = %agent.displayName
    if agent.acpStdioLaunchCommand.binary.len > 0:
      agentNode["acpStdioLaunchCommand"] = %*{
        "binary": agent.acpStdioLaunchCommand.binary,
        "args": agent.acpStdioLaunchCommand.args
      }
    agents.add agentNode
  result = %*{
    "tenantId": req.tenantId,
    "projectId": req.projectId,
    "prompt": prompt,
    "repo": {
      "mode": req.repo.mode,
      "url": req.repo.url,
      "branch": req.repo.branch,
      "commit": req.repo.commit
    },
    "runtime": {
      "type": req.runtime.kind,
      "devcontainerPath": req.runtime.devcontainerPath,
      "resources": {"cpu": req.runtime.cpu, "memoryMiB": req.runtime.memoryMiB}
    },
    "workspace": {
      "snapshotPreference": req.workspace.snapshotPreference,
      "executionHostId": req.workspace.executionHostId,
      "workingCopyMode": req.workspace.workingCopyMode
    },
    "sandbox": {
      "mode": req.sandbox.mode,
      "allow-network": req.sandbox.allowNetwork,
      "containers": req.sandbox.containers,
      "vm": req.sandbox.vm,
      "allow-kvm": req.sandbox.allowKvm,
      "debug": req.sandbox.debug,
      "rw-paths": req.sandbox.rwPaths,
      "overlay-paths": req.sandbox.overlayPaths,
      "blacklist-paths": req.sandbox.blacklistPaths,
      "tmpfs-size": req.sandbox.tmpfsSize,
      "limits": {
        "pids-max": req.sandbox.limits.pidsMax,
        "memory-max": req.sandbox.limits.memoryMax,
        "memory-high": req.sandbox.limits.memoryHigh,
        "cpu-max": req.sandbox.limits.cpuMax,
        "io-max": req.sandbox.limits.ioMax
      }
    },
    "agents": agents,
    "output": {
      "format": req.output.format,
      "flavor": req.output.flavor,
      "nonInteractive": req.output.nonInteractive
    },
    "delivery": {
      "mode": req.delivery.mode,
      "targetBranch": req.delivery.targetBranch
    },
    "labels": req.labels
  }
  if req.llmProvider.apiStyle.len > 0:
    result["llmProvider"] = %*{
      "apiStyle": req.llmProvider.apiStyle,
      "baseUrl": req.llmProvider.baseUrl,
      "apiKey": req.llmProvider.apiKey,
      "model": req.llmProvider.model
    }

proc taskResponseFromJson*(node: JsonNode): CreateTaskResponse =
  result.taskId = node{"task_id"}.getStr("")
  result.status = node{"status"}.getStr("")
  for idNode in node{"session_ids"}.items:
    result.sessionIds.add idNode.getStr("")
  result.links = LinkSet(
    self: node{"links"}{"self"}.getStr(""),
    events: node{"links"}{"events"}.getStr(""),
    logs: node{"links"}{"logs"}.getStr(""))

proc promptAcceptedFromJson*(node: JsonNode): PromptAcceptedResponse =
  PromptAcceptedResponse(
    sessionId: node{"sessionId"}.getStr(""),
    accepted: node{"accepted"}.getBool(false),
    ts: node{"ts"}.getStr(""))

proc eventFromJson*(node: JsonNode): HarborEvent =
  let kind = node{"type"}.getStr("unknown")
  case kind
  of "log": result.kind = hekLog
  of "thought": result.kind = hekThought
  of "tool_use": result.kind = hekToolUse
  of "tool_result": result.kind = hekToolResult
  of "file_edit": result.kind = hekFileEdit
  of "diff": result.kind = hekDiff
  of "workspace": result.kind = hekWorkspace
  of "delivery": result.kind = hekDelivery
  of "llm_request": result.kind = hekLlmRequest
  of "sub_agent": result.kind = hekSubAgent
  of "status": result.kind = hekStatus
  else: result.kind = hekUnknown
  result.message = node{"message"}.getStr(node{"thought"}.getStr(""))
  result.status = node{"status"}.getStr("")
  result.level = node{"level"}.getStr("")
  result.toolName = node{"tool_name"}.getStr("")
  result.toolExecutionId = node{"tool_execution_id"}.getStr("")
  result.filePath = node{"file_path"}.getStr(node{"path"}.getStr(""))
  result.linesAdded = node{"lines_added"}.getInt(0)
  result.linesRemoved = node{"lines_removed"}.getInt(0)
  result.mountPath = node{"mountPath"}.getStr("")
  result.provider = node{"provider"}.getStr("")
  result.workingCopyMode = node{"workingCopyMode"}.getStr("")
  result.deliveryMode = node{"mode"}.getStr("")
  result.deliveryUrl = node{"url"}.getStr("")
  result.ts = node{"ts"}.getStr("")
  result.timestamp = node{"timestamp"}.getBiggestInt(0)
  result.raw = node

proc eventHistoryFromJson*(node: JsonNode): EventHistoryResponse =
  for item in node{"events"}.items:
    result.events.add eventFromJson(item)
  result.hasMore = node{"has_more"}.getBool(false)
  result.oldestTimestamp = node{"oldest_timestamp"}.getBiggestInt(0)
  result.totalCount = node{"total_count"}.getInt(0)
