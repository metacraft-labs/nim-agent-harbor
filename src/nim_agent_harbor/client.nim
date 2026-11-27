import std/json
import std/strutils
import std/uri
import nim_everywhere
import nim_agent_harbor/types

type
  HarborStreamCallback* = proc(event: HarborEvent; cursor: string): bool {.closure.}
  HarborStreamTransport* = proc(request: HttpRequest; onEvent: HarborStreamCallback) {.closure.}
  HarborFrameCallback* = proc(frame: SseFrame): bool {.closure.}
    ## Receives each frame of an event stream; returning false stops it.
  HarborFrameStreamTransport* = proc(request: HttpRequest;
    onFrame: HarborFrameCallback) {.closure.}
    ## Opens an event stream and hands each frame to `onFrame` as it arrives,
    ## until `onFrame` returns false. Raises `HarborError` when the server
    ## refuses the request or the stream ends or stalls.
  HarborClient* = object
    baseUrl*: string
    auth*: HarborAuth
    transport*: HttpTransport
    streamTransport*: HarborStreamTransport
      ## Carries a session's event stream; nil reads it with `transport`.
    frameStreamTransport*: HarborFrameStreamTransport
      ## Carries the session lifecycle feed; nil reads it with `transport`,
      ## which suits a server that closes the stream (a fake or a capture)
      ## and never a live one, whose feed does not end.

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

proc readEventHistoryJson*(client: HarborClient; sessionId: string;
    limit = 0; before = 0'i64): JsonNode =
  ## `GET /api/v1/sessions/{id}/events/history` as the server's JSON: the
  ## newest `limit` events (the server's default when 0, at most 200), newest
  ## first, older than `before` (a timestamp in ms) when it is not 0, with
  ## `total_count`, `has_more` and `oldest_timestamp`. For a reader that folds
  ## the events as sent, with every field the typed `readEventHistory` drops.
  ##
  ## The history counts every event of the session, the first included; that
  ## event is the one the session's stream (`followSessionEvents`) sends
  ## without an id, so the event at position p, oldest first, is the stream's
  ## frame of id p - 1 (measured against a running server, 2026-11-27).
  let response = client.transport.request(newRequest(
    hmGet,
    client.baseUrl & historyPath(sessionId,
      EventHistoryQuery(limit: limit, before: before)),
    "",
    @[header("Accept", "application/json")] & client.auth.authHeaders()))
  if response.status < 200 or response.status >= 300:
    raise newException(HarborError, "Harbor session event history failed (HTTP " &
      $response.status & "): " & response.body)
  result = parseJson(response.body)
  if result.kind != JObject or result{"events"}.isNil or
      result{"events"}.kind != JArray:
    raise newException(HarborError,
      "Harbor session event history is not an events page: " & response.body)

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

type
  SseReader* = object
    ## Incremental reader of a `text/event-stream` body, fed one line at a
    ## time. It implements the parts of the format the Harbor streams use
    ## (https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation):
    ## `event`, `data` (repeated lines joined by a newline), `id`, comments,
    ## one optional space after the colon, and dispatch at a blank line when
    ## the block carried data. `retry` and unknown fields are ignored. Unlike
    ## a browser, it reports each block's own `id` rather than carrying the
    ## last one forward, because a Harbor cursor names the frame it came with.
    event: string
    data: string
    id: string
    hasData: bool

proc initSseReader*(): SseReader = SseReader()

proc feedLine*(reader: var SseReader; line: string; frame: var SseFrame): bool =
  ## Feeds one line, without its terminator (a trailing CR is dropped).
  ## Returns true, with `frame` set, when the line completes an event.
  let line = if line.endsWith('\r'): line[0 ..< ^1] else: line
  if line.len == 0:
    if reader.hasData:
      frame = SseFrame(event: (if reader.event.len > 0: reader.event else: "message"),
        data: reader.data, id: reader.id)
      result = true
    reader = SseReader()
    return
  if line[0] == ':':
    return false
  let colon = line.find(':')
  var field = line
  var value = ""
  if colon >= 0:
    field = line[0 ..< colon]
    value = line[colon + 1 .. ^1]
    if value.startsWith(' '): value = value[1 .. ^1]
  case field
  of "event":
    reader.event = value
  of "data":
    if reader.hasData: reader.data.add '\n'
    reader.data.add value
    reader.hasData = true
  of "id":
    # The format ignores an id that contains NUL.
    if '\0' notin value: reader.id = value
  else:
    discard

proc parseSseFrames*(text: string): seq[SseFrame] =
  ## The events of a whole event-stream body. A last block that is not ended
  ## by a blank line is incomplete and yields nothing, as the format says.
  var reader = initSseReader()
  var frame: SseFrame
  for line in text.splitLines:
    if reader.feedLine(line, frame):
      result.add frame

proc addEncoded(parts: var seq[string]; name, value: string) =
  if value.len > 0:
    parts.add name & "=" & encodeUrl(value, usePlus = false)

proc sessionsPath(query: SessionListQuery): string =
  var parts: seq[string] = @[]
  parts.addEncoded("status", query.status)
  if query.page > 0: parts.add "page=" & $query.page
  if query.perPage > 0: parts.add "perPage=" & $query.perPage
  "/api/v1/sessions" & queryJoin(parts)

proc parseBodyOrRaise(body, what: string): JsonNode =
  ## The body as JSON, or `HarborError` naming `what`. On the JS backend
  ## `parseJson` throws the engine's own `SyntaxError`, which no Nim
  ## exception type catches, so the bare `except` is what keeps a body that
  ## is not JSON from escaping as a foreign exception there.
  try:
    result = parseJson(body)
  except JsonParsingError as error:
    raise newException(HarborError, what & " is not JSON: " & error.msg)
  except:
    raise newException(HarborError, what & " is not JSON")

proc listSessions*(client: HarborClient;
    query = SessionListQuery()): SessionListPage =
  ## One page of `GET /api/v1/sessions`: the sessions the caller may list.
  ## A refusal or an unreadable body raises `HarborError`, so a failed
  ## refresh never reads as an empty fleet.
  let response = client.transport.request(newRequest(hmGet,
    client.baseUrl & sessionsPath(query), "",
    @[header("Accept", "application/json")] & client.auth.authHeaders()))
  if response.status < 200 or response.status >= 300:
    raise newException(HarborError, "Harbor session list failed (HTTP " &
      $response.status & "): " & response.body)
  sessionListPageFromJson(parseBodyOrRaise(response.body, "Harbor session list"))

proc listAllSessions*(client: HarborClient; query = SessionListQuery();
    perPage = 200): seq[JsonNode] =
  ## Every session of `GET /api/v1/sessions`, following `nextPage` from page
  ## 1 (`perPage` rows a page; the server's maximum is 200). A `nextPage`
  ## that does not move forward, or a page that is empty but names a next
  ## one, raises `HarborError` rather than looping.
  var paged = query
  paged.perPage = perPage
  paged.page = 1
  while true:
    let page = client.listSessions(paged)
    result.add page.items
    if page.nextPage == 0: return
    if page.nextPage <= paged.page or page.items.len == 0:
      raise newException(HarborError, "Harbor session list page " & $paged.page &
        " names next page " & $page.nextPage)
    paged.page = page.nextPage

proc lifecyclePath(after: string): string =
  var parts: seq[string] = @[]
  parts.addEncoded("after", after)
  "/api/v1/session-lifecycle/events" & queryJoin(parts)

proc followSessionLifecycle*(client: HarborClient; onFrame: HarborFrameCallback;
    after = "") =
  ## Follows `GET /api/v1/session-lifecycle/events`, handing each frame to
  ## `onFrame` until it returns false. Frames are `lifecycle` (with an
  ## `<epoch>-<seq>` cursor in `id`), `resync` (rebuild from `listSessions`;
  ## sent first when `after` cannot be replayed) and `caught_up` (the replay
  ## after a valid `after` is over). `after` is the last cursor the caller
  ## applied, "" for none; it is sent as `?after=`, which the server prefers
  ## over `Last-Event-ID`.
  let request = newRequest(hmGet, client.baseUrl & lifecyclePath(after), "",
    @[header("Accept", "text/event-stream")] & client.auth.authHeaders())
  if client.frameStreamTransport != nil:
    client.frameStreamTransport(request, onFrame)
    return
  let response = client.transport.request(request)
  if response.status < 200 or response.status >= 300:
    raise newException(HarborError, "Harbor session lifecycle feed failed (HTTP " &
      $response.status & "): " & response.body)
  for frame in parseSseFrames(response.body):
    if not onFrame(frame): return

proc followSessionEvents*(client: HarborClient; sessionId: string;
    onFrame: HarborFrameCallback; after = "") =
  ## Follows `GET /api/v1/sessions/{id}/events`, handing each frame (event
  ## `session`, the event's JSON in `data`) to `onFrame` until it returns
  ## false. Opened with no `after`, the server replays the whole session and
  ## then follows it live; with `after`, the last id the caller applied, sent
  ## as `Last-Event-ID`, it resends that event and then sends the ones after
  ## it. Each event has a sequential id from 1, except the first frame of a
  ## connection, which carries none: the session's first event on a replay
  ## from the start, the resent event `after` on a resume (measured against a
  ## running server, 2026-11-27). Unlike `streamSessionEvents`, the frames
  ## are not parsed into typed events.
  var headers = @[header("Accept", "text/event-stream")] & client.auth.authHeaders()
  if after.len > 0: headers.add header("Last-Event-ID", after)
  let request = newRequest(hmGet,
    client.baseUrl & "/api/v1/sessions/" & sessionId & "/events", "", headers)
  if client.frameStreamTransport != nil:
    client.frameStreamTransport(request, onFrame)
    return
  let response = client.transport.request(request)
  if response.status < 200 or response.status >= 300:
    raise newException(HarborError, "Harbor session event stream failed (HTTP " &
      $response.status & "): " & response.body)
  for frame in parseSseFrames(response.body):
    if not onFrame(frame): return

# ---------------------------------------------------------------------------
# The inbox and its cursors
# ---------------------------------------------------------------------------
#
# Every request shape the inbox calls send is in this section, so a change of
# the wire is made here alone: the paths, the query parameters, the body of a
# cursor move. The answers are returned as JSON for the caller to read (as
# `listSessions` returns its items), so the items' and the cursor's shapes are
# read in one place too, by the caller.

type
  InboxQuery* = object
    ## The scope of an inbox read or stream, as on `GET /api/v1/sessions`.
    cursor*: string
      ## `?cursor=<name>`: the read also carries that cursor's position and
      ## the targets of its next presses (`ahead`). "" for none.
    orgId*, projectId*: string

  InboxCursorDirection* = enum
    icNext = "next"
    icPrev = "prev"

  InboxCursorMove* = object
    ## One press of Next or Prev, sent to the server after the front-end has
    ## already switched to `landedOn`.
    direction*: InboxCursorDirection
    expectedVersion*: int64
      ## The `cursorVersion` the caller's `ahead` was based on;
      ## `NoCursorVersion` when it holds none.
    landedOn*: string
      ## The item id the caller switched to; "" when it switched to none
      ## and waits for the answer.

const
  DefaultInboxCursor* = "default"
    ## The caller's one walk through the inbox, shared by all of its devices
    ## and front-ends.
  NoCursorVersion* = -1'i64

proc cursorMove*(direction: InboxCursorDirection;
    expectedVersion = NoCursorVersion; landedOn = ""): InboxCursorMove =
  InboxCursorMove(direction: direction, expectedVersion: expectedVersion,
    landedOn: landedOn)

proc validCursorName*(name: string): bool =
  ## A cursor name the server accepts: `[a-z0-9-]{1,64}`.
  if name.len < 1 or name.len > 64: return false
  for c in name:
    if c notin {'a'..'z', '0'..'9', '-'}: return false
  true

proc inboxQueryParts(query: InboxQuery): seq[string] =
  result.addEncoded("cursor", query.cursor)
  result.addEncoded("org_id", query.orgId)
  result.addEncoded("project_id", query.projectId)

proc inboxPath*(query = InboxQuery()): string =
  "/api/v1/inbox" & queryJoin(inboxQueryParts(query))

proc inboxEventsPath*(query = InboxQuery()): string =
  var scoped = query
  scoped.cursor = ""   # the stream names the caller's cursors itself
  "/api/v1/inbox/events" & queryJoin(inboxQueryParts(scoped))

proc cursorMovePath*(name: string; direction: InboxCursorDirection;
    query = InboxQuery()): string =
  var scoped = query
  scoped.cursor = ""
  "/api/v1/inbox/cursors/" & name & "/" & $direction &
    queryJoin(inboxQueryParts(scoped))

proc cursorMoveBody*(move: InboxCursorMove): string =
  ## `{"expectedVersion", "landedOn"}`, each only when the caller has one.
  var body = newJObject()
  if move.expectedVersion >= 0: body["expectedVersion"] = %move.expectedVersion
  if move.landedOn.len > 0: body["landedOn"] = %move.landedOn
  $body

proc checkCursorName(name: string) =
  if not validCursorName(name):
    raise newException(HarborError, "Harbor inbox cursor name is invalid: '" &
      name & "' (expected [a-z0-9-]{1,64})")

proc getInbox*(client: HarborClient; query = InboxQuery()): JsonNode =
  ## `GET /api/v1/inbox`: every item waiting for the operator, in the
  ## server's order, and with `query.cursor` that cursor's position and
  ## `ahead`. A refusal or a body that is not an object with an `items` list
  ## raises `HarborError`, so a failed read never reads as an empty inbox.
  if query.cursor.len > 0: checkCursorName(query.cursor)
  let response = client.transport.request(newRequest(hmGet,
    client.baseUrl & inboxPath(query), "",
    @[header("Accept", "application/json")] & client.auth.authHeaders()))
  if response.status < 200 or response.status >= 300:
    raise newException(HarborError, "Harbor inbox read failed (HTTP " &
      $response.status & "): " & response.body)
  result = parseBodyOrRaise(response.body, "Harbor inbox")
  if result.kind != JObject or result{"items"}.isNil or
      result["items"].kind != JArray:
    raise newException(HarborError, "Harbor inbox has no items list: " &
      response.body)

proc moveInboxCursor*(client: HarborClient; name: string;
    move: InboxCursorMove; query = InboxQuery()): JsonNode =
  ## `POST /api/v1/inbox/cursors/{name}/next` or `…/prev`. Returns the answer
  ## (`item`, the item landed on or null; `visitedDepth`; `cursorVersion`;
  ## `ahead`). A refusal, a 404 from a server without cursors among them, or
  ## an answer without `item` raises `HarborError`: a failed move never
  ## reads as "nothing to move to".
  checkCursorName(name)
  let response = client.transport.request(newRequest(hmPost,
    client.baseUrl & cursorMovePath(name, move.direction, query),
    cursorMoveBody(move),
    @[header("Accept", "application/json"),
      header("Content-Type", "application/json; charset=utf-8")] &
      client.auth.authHeaders()))
  if response.status < 200 or response.status >= 300:
    raise newException(HarborError, "Harbor inbox cursor " & $move.direction &
      " failed (HTTP " & $response.status & "): " & response.body)
  result = parseBodyOrRaise(response.body, "Harbor inbox cursor answer")
  if result.kind != JObject or not result.hasKey("item"):
    raise newException(HarborError, "Harbor inbox cursor answer has no item: " &
      response.body)

proc followInbox*(client: HarborClient; onFrame: HarborFrameCallback;
    query = InboxQuery(); lastEventId = "") =
  ## Follows `GET /api/v1/inbox/events`, handing each frame to `onFrame`
  ## until it returns false. The stream notifies and carries no items:
  ## `resync` (read the inbox again; always the first frame) and `changed`
  ## (what changed, and with the `cursor` reason the caller's cursors' moves).
  ## `id` is `<epoch>:<seq>`. `lastEventId`, sent as `Last-Event-ID`, only
  ## tells the server this is a reconnection: the stream keeps no history,
  ## so it starts over with a `resync` either way.
  var headers = @[header("Accept", "text/event-stream")]
  if lastEventId.len > 0: headers.add header("Last-Event-ID", lastEventId)
  let request = newRequest(hmGet, client.baseUrl & inboxEventsPath(query), "",
    headers & client.auth.authHeaders())
  if client.frameStreamTransport != nil:
    client.frameStreamTransport(request, onFrame)
    return
  let response = client.transport.request(request)
  if response.status < 200 or response.status >= 300:
    raise newException(HarborError, "Harbor inbox stream failed (HTTP " &
      $response.status & "): " & response.body)
  for frame in parseSseFrames(response.body):
    if not onFrame(frame): return
