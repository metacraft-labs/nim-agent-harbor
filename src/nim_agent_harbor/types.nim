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
    prompt*: string
    repo*: RepoConfig
    runtime*: RuntimeConfig
    workspacePath*: string
    workingCopyMode*: string
    executionHostId*: string
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
  var agents = newJArray()
  for agent in req.agents:
    let settings =
      if agent.settings.isNil: newJObject()
      else: agent.settings.copy()
    if agent.model.len > 0:
      settings["model"] = %agent.model
    var agentNode = %*{
      "type": agent.agent.software,
      "version": agent.agent.version,
      "count": agent.count,
      "settings": settings
    }
    if agent.displayName.len > 0:
      agentNode["display_name"] = %agent.displayName
    if agent.acpStdioLaunchCommand.binary.len > 0:
      agentNode["acpStdioLaunchCommand"] = %*{
        "binary": agent.acpStdioLaunchCommand.binary,
        "args": agent.acpStdioLaunchCommand.args
      }
    agents.add agentNode
  var sandbox = newJObject()
  if req.sandbox.mode.len > 0:
    sandbox["mode"] = %req.sandbox.mode
  if req.sandbox.allowNetwork:
    sandbox["allow-network"] = %req.sandbox.allowNetwork
  if req.sandbox.containers:
    sandbox["containers"] = %req.sandbox.containers
  if req.sandbox.vm:
    sandbox["vm"] = %req.sandbox.vm
  if req.sandbox.allowKvm:
    sandbox["allow-kvm"] = %req.sandbox.allowKvm
  if req.sandbox.debug:
    sandbox["debug"] = %req.sandbox.debug
  if req.sandbox.rwPaths.len > 0:
    sandbox["rw-paths"] = %req.sandbox.rwPaths
  if req.sandbox.overlayPaths.len > 0:
    sandbox["overlay-paths"] = %req.sandbox.overlayPaths
  if req.sandbox.blacklistPaths.len > 0:
    sandbox["blacklist-paths"] = %req.sandbox.blacklistPaths
  if req.sandbox.tmpfsSize.len > 0:
    sandbox["tmpfs-size"] = %req.sandbox.tmpfsSize
  var limits = newJObject()
  if req.sandbox.limits.pidsMax != 0:
    limits["pids-max"] = %req.sandbox.limits.pidsMax
  if req.sandbox.limits.memoryMax.len > 0:
    limits["memory-max"] = %req.sandbox.limits.memoryMax
  if req.sandbox.limits.memoryHigh.len > 0:
    limits["memory-high"] = %req.sandbox.limits.memoryHigh
  if req.sandbox.limits.cpuMax.len > 0:
    limits["cpu-max"] = %req.sandbox.limits.cpuMax
  if req.sandbox.limits.ioMax.len > 0:
    limits["io-max"] = %req.sandbox.limits.ioMax
  if limits.len > 0:
    sandbox["limits"] = limits
  result = %*{
    "tenantId": req.tenantId,
    "projectId": req.projectId,
    "prompt": req.prompt,
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
  if sandbox.len > 0:
    result["sandbox"] = sandbox
  if req.workspacePath.len > 0:
    result["workspace_path"] = %req.workspacePath
  if req.workingCopyMode.len > 0:
    result["working_copy_mode"] = %req.workingCopyMode
  if req.executionHostId.len > 0:
    result["workspace"] = %*{"executionHostId": req.executionHostId}
  if req.llmProvider.apiStyle.len > 0:
    result["llmProvider"] = %*{
      "apiStyle": req.llmProvider.apiStyle,
      "baseUrl": req.llmProvider.baseUrl,
      "apiKey": req.llmProvider.apiKey,
      "model": req.llmProvider.model
    }

proc taskResponseFromJson*(node: JsonNode): CreateTaskResponse =
  let responseNode =
    if node.kind == JString:
      parseJson(node.getStr())
    else:
      node
  result.taskId =
    if responseNode.hasKey("task_id"): responseNode["task_id"].getStr("")
    else: responseNode{"taskId"}.getStr("")
  result.status = responseNode{"status"}.getStr("")
  let sessionIdsNode =
    if responseNode.hasKey("session_ids"): responseNode["session_ids"]
    elif responseNode.hasKey("sessionIds"): responseNode["sessionIds"]
    else: newJArray()
  for idNode in sessionIdsNode.items:
    result.sessionIds.add idNode.getStr("")
  result.links = LinkSet(
    self: responseNode{"links"}{"self"}.getStr(""),
    events: responseNode{"links"}{"events"}.getStr(""),
    logs: responseNode{"links"}{"logs"}.getStr(""))

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
  of "workspace", "workspace_ready": result.kind = hekWorkspace
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
  result.mountPath = node{"mountPath"}.getStr(node{"mount_path"}.getStr(
    node{"workspace_path"}.getStr(""))
  )
  result.provider = node{"provider"}.getStr("")
  result.workingCopyMode = node{"workingCopyMode"}.getStr(
    node{"working_copy_mode"}.getStr(""))
  result.deliveryMode = node{"mode"}.getStr("")
  result.deliveryUrl = node{"url"}.getStr("")
  result.ts = node{"ts"}.getStr("")
  result.timestamp = node{"timestamp"}.getBiggestInt(0)
  result.raw = node

proc eventHistoryFromJson*(node: JsonNode): EventHistoryResponse =
  let historyNode =
    if node.kind == JString:
      parseJson(node.getStr())
    else:
      node
  let eventsNode =
    if historyNode.kind == JArray:
      historyNode
    elif historyNode.kind == JObject and historyNode.hasKey("events"):
      historyNode["events"]
    else:
      newJArray()
  for item in eventsNode.items:
    result.events.add eventFromJson(item)
  result.hasMore = historyNode{"has_more"}.getBool(
    historyNode{"hasMore"}.getBool(false))
  result.oldestTimestamp = historyNode{"oldest_timestamp"}.getBiggestInt(
    historyNode{"oldestTimestamp"}.getBiggestInt(0))
  result.totalCount = historyNode{"total_count"}.getInt(
    historyNode{"totalCount"}.getInt(result.events.len))
