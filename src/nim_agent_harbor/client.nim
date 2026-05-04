import std/json
import std/strutils
import nim_everywhere
import nim_agent_harbor/types

type
  HarborClient* = object
    baseUrl*: string
    auth*: HarborAuth
    transport*: HttpTransport

proc authHeaders*(auth: HarborAuth): seq[HttpHeader] =
  case auth.kind
  of akNone: @[]
  of akApiKey: @[header("X-API-Key", auth.token)]
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

proc createTask*(client: HarborClient; req: CreateTaskRequest): CreateTaskResponse =
  let response = client.transport.request(newRequest(
    hmPost,
    client.baseUrl & "/api/v1/tasks",
    $taskToJson(req),
    @[header("Content-Type", "application/json; charset=utf-8")] & client.auth.authHeaders()))
  if response.status < 200 or response.status >= 300:
    raise newException(HarborError, response.body)
  taskResponseFromJson(parseJson(response.body))

proc sendPrompt*(client: HarborClient; sessionId: string;
    prompt: seq[HarborContentBlock]): PromptAcceptedResponse =
  var blocks = newJArray()
  for item in prompt:
    blocks.add contentBlockToJson(item)
  let response = client.transport.request(newRequest(
    hmPost,
    client.baseUrl & "/api/v1/sessions/" & sessionId & "/prompt",
    $(%*{"prompt": blocks}),
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
