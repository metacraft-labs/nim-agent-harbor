import std/json
import std/strutils
import nim_everywhere
import nim_agent_harbor/types

type
  HarborStreamCallback* = proc(event: HarborEvent; cursor: string): bool {.closure.}
  HarborStreamTransport* = proc(request: HttpRequest; onEvent: HarborStreamCallback) {.closure.}
  HarborClient* = object
    baseUrl*: string
    auth*: HarborAuth
    transport*: HttpTransport
    streamTransport*: HarborStreamTransport

proc authHeaders*(auth: HarborAuth): seq[HttpHeader] =
  case auth.kind
  of akNone: @[]
  of akApiKey: @[header("Authorization", "ApiKey " & auth.token)]
  of akBearer: @[header("Authorization", "Bearer " & auth.token)]

proc newHarborClient*(baseUrl: string; transport: HttpTransport;
    auth = HarborAuth(kind: akNone)): HarborClient =
  HarborClient(baseUrl: baseUrl.strip(leading = false, trailing = true, chars = {'/'}),
    transport: transport, auth: auth)

proc queryJoin(parts: seq[string]): string =
  if parts.len == 0: ""
  else: "?" & parts.join("&")

proc addParam(parts: var seq[string]; name, value: string) =
  if value.len > 0:
    parts.add name & "=" & value

proc eventsPath(sessionId: string; query: EventsQuery): string =
  var parts: seq[string] = @[]
  if query.types.len > 0:
    parts.add "type=" & query.types.join(",")
  parts.addParam("level", query.level)
  parts.addParam("since", query.since)
  parts.addParam("until", query.until)
  if query.page > 0:
    parts.add "page=" & $query.page
  if query.perPage > 0:
    parts.add "perPage=" & $query.perPage
  parts.addParam("sort", query.sort)
  "/api/v1/sessions/" & sessionId & "/events" & queryJoin(parts)

proc historyPath(sessionId: string; query: EventHistoryQuery): string =
  var parts: seq[string] = @[]
  if query.limit > 0:
    parts.add "limit=" & $query.limit
  if query.before > 0:
    parts.add "before=" & $query.before
  "/api/v1/sessions/" & sessionId & "/events/history" & queryJoin(parts)

type
  HarborTaskReport* = object
    ## Snapshot of a Harbor session's server-side state used by the
    ## codetracer ViewModel to refresh per-session entries after the
    ## workspace provisioning step lands or the agent's lifecycle
    ## transitions. ``raw`` is the complete parsed JSON body so callers can
    ## reach into provider-specific fields without forcing the
    ## structured surface to grow ahead of upstream. The session endpoint
    ## does not provide ``taskId``; ``sessionIds`` contains the requested ID.
    taskId*: string
    sessionIds*: seq[string]
    workspacePath*: string
    workingCopyMode*: string
    status*: string
    raw*: JsonNode

proc fetchTaskReport*(client: HarborClient; sessionId: string): HarborTaskReport =
  ## Pull the canonical session snapshot, preserving its JSON in ``raw``.
  ## A session snapshot does not enumerate sibling sessions or identify its
  ## orchestration task. Non-2xx responses raise ``HarborError`` so a failed
  ## refresh cannot replace the caller's last known state with empty values.
  result.sessionIds = @[sessionId]
  let response = client.transport.request(newRequest(
    hmGet,
    client.baseUrl & "/api/v1/sessions/" & sessionId,
    "",
    @[header("Accept", "application/json")] & client.auth.authHeaders()))
  if response.status < 200 or response.status >= 300:
    raise newException(HarborError,
      "Harbor session refresh failed (HTTP " & $response.status & "): " & response.body)
  let parsed = parseJson(response.body)
  result.raw = parsed
  result.workspacePath = parsed{"workspace", "mountPath"}.getStr("")
  # The server stores the requested working-copy mode as snapshotProvider,
  # and exposes that same value as working_copy_mode on /sessions/{id}/info.
  result.workingCopyMode = parsed{"workspace", "snapshotProvider"}.getStr("")
  result.status = parsed{"status"}.getStr("")

proc createTask*(client: HarborClient; req: CreateTaskRequest): CreateTaskResponse =
  let response = client.transport.request(newRequest(
    hmPost,
    client.baseUrl & "/api/v1/tasks",
    $taskToJson(req),
    @[header("Content-Type", "application/json; charset=utf-8")] & client.auth.authHeaders()))
  if response.status < 200 or response.status >= 300:
    raise newException(HarborError, response.body)
  taskResponseFromJson(parseJson(response.body))

proc createSession*(client: HarborClient; req: CreateSessionRequest): CreateSessionResponse =
  ## Create a standalone session with its first user prompt, not an orchestration task.
  if req.prompt.strip().len == 0:
    raise newException(HarborError, "Harbor session creation requires an initial prompt")
  let response = client.transport.request(newRequest(
    hmPost, client.baseUrl & "/api/v1/sessions", $sessionToJson(req),
    @[header("Content-Type", "application/json; charset=utf-8")] & client.auth.authHeaders()))
  if response.status < 200 or response.status >= 300:
    raise newException(HarborError, response.body)
  sessionResponseFromJson(parseJson(response.body))

proc sendPrompt*(client: HarborClient; sessionId: string;
    prompt: seq[HarborContentBlock]): PromptAcceptedResponse =
  var text: seq[string] = @[]
  for item in prompt:
    if item.kind != hcbText:
      raise newException(HarborError, "Harbor REST prompts currently accept text only")
    text.add item.text
  let response = client.transport.request(newRequest(
    hmPost,
    client.baseUrl & "/api/v1/sessions/" & sessionId & "/prompt",
    $(%*{"prompt": text.join("\n")}),
    @[header("Content-Type", "application/json; charset=utf-8")] & client.auth.authHeaders()))
  if response.status < 200 or response.status >= 300:
    raise newException(HarborError, response.body)
  promptAcceptedFromJson(parseJson(response.body))

proc parseSseEvents*(sseText: string): seq[HarborEvent]

proc readSessionEvents*(client: HarborClient; sessionId: string;
    query = EventsQuery()): seq[HarborEvent] =
  let response = client.transport.request(newRequest(
    hmGet,
    client.baseUrl & eventsPath(sessionId, query),
    "",
    @[header("Accept", "text/event-stream, application/json")] & client.auth.authHeaders()))
  if response.status < 200 or response.status >= 300:
    raise newException(HarborError, response.body)
  if response.body.strip().startsWith("{") or response.body.strip().startsWith("["):
    let node = parseJson(response.body)
    if node.kind == JArray:
      for item in node.items:
        result.add eventFromJson(item)
    else:
      for item in node{"events"}.items:
        result.add eventFromJson(item)
  else:
    result = parseSseEvents(response.body)

proc subscribeSessionEvents*(client: HarborClient; sessionId: string;
    onEvent: proc(event: HarborEvent) {.closure.};
    query = EventsQuery()) =
  for event in client.readSessionEvents(sessionId, query):
    onEvent(event)

proc readEventHistory*(client: HarborClient; sessionId: string;
    query = EventHistoryQuery()): EventHistoryResponse =
  let response = client.transport.request(newRequest(
    hmGet,
    client.baseUrl & historyPath(sessionId, query),
    "",
    @[header("Accept", "application/json")] & client.auth.authHeaders()))
  if response.status < 200 or response.status >= 300:
    raise newException(HarborError, response.body)
  eventHistoryFromJson(parseJson(response.body))

proc parseSseEvents*(sseText: string): seq[HarborEvent] =
  var events: seq[HarborEvent] = @[]
  var dataLines: seq[string] = @[]
  proc flush() =
    if dataLines.len == 0:
      return
    let data = dataLines.join("\n")
    events.add eventFromJson(parseJson(data))
    dataLines = @[]
  for line in sseText.splitLines:
    if line.len == 0:
      flush()
    elif line.startsWith("data:"):
      dataLines.add line[5 .. ^1].strip()
  flush()
  events

proc streamSessionEvents*(client: HarborClient; sessionId: string;
    onEvent: HarborStreamCallback; after = "") =
  ## Follow the durable event stream, stopping when the consumer returns false.
  ## A cursor belongs to one session and is supplied again on the next turn.
  if client.streamTransport == nil:
    for event in client.readSessionEvents(sessionId):
      if not onEvent(event, ""): break
    return
  var headers = @[header("Accept", "text/event-stream")] & client.auth.authHeaders()
  if after.len > 0: headers.add header("Last-Event-ID", after)
  client.streamTransport(newRequest(hmGet,
    client.baseUrl & "/api/v1/sessions/" & sessionId & "/events", "", headers), onEvent)

proc stopSession*(client: HarborClient; sessionId: string) =
  let response = client.transport.request(newRequest(hmPost,
    client.baseUrl & "/api/v1/sessions/" & sessionId & "/stop", "{}",
    @[header("Content-Type", "application/json")] & client.auth.authHeaders()))
  if response.status < 200 or response.status >= 300:
    raise newException(HarborError, response.body)
