## The inbox calls a front-end needs to walk the operator's inbox:
## `GET /api/v1/inbox`, `GET /api/v1/inbox/events` and
## `POST /api/v1/inbox/cursors/{name}/next|prev`.
##
## The HTTP peer is a recording closure, as in `test_session_fleet.nim`: these
## cases pin the request each call sends (method, path, query, headers, body)
## and how each answer is read, on the native and the JS backend. Two answers
## were captured from a real `ah server` (`inbox-empty.json`,
## `cursor-no-route.json`); the others are shaped from the REST contract
## because no server serves them yet (`tests/fixtures/README.md`). A case that
## rests on a shape the contract does not spell out says so in its name:
## "(shape guessed: …)".
import std/[json, strutils]
import unittest
import nim_everywhere
import nim_agent_harbor

const
  base = "http://127.0.0.1:18081"
  emptyBody = staticRead("fixtures/inbox/inbox-empty.json")
  cursorInboxBody = staticRead("fixtures/inbox/inbox-cursor.json")
  nextBody = staticRead("fixtures/inbox/cursor-next.json")
  emptyMoveBody = staticRead("fixtures/inbox/cursor-empty.json")
  noRouteBody = staticRead("fixtures/inbox/cursor-no-route.json")
  eventsFeed = staticRead("fixtures/inbox/inbox-events.sse")
  firstItem = "01HW00000000000000000000A1@1793826001000"
  secondItem = "01HW00000000000000000000B2@1793826002000"

type Recorder = ref object
  requests: seq[HttpRequest]

proc answering(recorder: Recorder;
    answer: proc(req: HttpRequest): HttpResponse): HttpTransport =
  result = proc(req: HttpRequest): HttpResponse =
    recorder.requests.add req
    answer(req)

proc headerValue(req: HttpRequest; name: string): string =
  for item in req.headers:
    if item.name.cmpIgnoreCase(name) == 0: return item.value

proc ok(body: string): HttpResponse = HttpResponse(status: 200, body: body)

proc serving(recorder: Recorder; body: string; status = 200): HttpTransport =
  recorder.answering(proc(req: HttpRequest): HttpResponse =
    HttpResponse(status: status, body: body))

suite "reading the inbox":
  test "the read request, and the captured empty inbox":
    let recorder = Recorder()
    let client = newHarborClient(base & "/", recorder.serving(emptyBody),
      bearerAuth("tok"))
    let inbox = client.getInbox()
    check recorder.requests.len == 1
    let req = recorder.requests[0]
    check req.httpMethod == hmGet
    check req.url == base & "/api/v1/inbox"
    check req.headerValue("Accept") == "application/json"
    check req.headerValue("Authorization") == "Bearer tok"
    check inbox["items"].len == 0

  test "a cursor and the scope go in the query":
    let recorder = Recorder()
    let client = newHarborClient(base, recorder.serving(cursorInboxBody))
    discard client.getInbox(InboxQuery(cursor: DefaultInboxCursor,
      orgId: "org 1", projectId: "p-2"))
    check recorder.requests[0].url ==
      base & "/api/v1/inbox?cursor=default&org_id=org%201&project_id=p-2"

  test "a read with a cursor keeps the items in the server's order (shape guessed: the cursor block)":
    let client = newHarborClient(base, Recorder().serving(cursorInboxBody))
    let inbox = client.getInbox(InboxQuery(cursor: DefaultInboxCursor))
    var ids: seq[string] = @[]
    for item in inbox["items"]: ids.add item["id"].getStr()
    check ids[0] == firstItem
    check ids[1] == secondItem
    check ids.len == 3
    # A fresh cursor: Next lands on the top, then the top excluding the item
    # on screen; Prev wraps to the last item and stays there.
    var next, prev: seq[string] = @[]
    for id in inbox["ahead"]["next"]: next.add id.getStr()
    for id in inbox["ahead"]["prev"]: prev.add id.getStr()
    check next == @[firstItem, secondItem, firstItem]
    check prev == @[ids[2]]
    check inbox["cursor"]["cursorVersion"].getInt() == 0

  test "a refused read raises and names the status":
    let client = newHarborClient(base, Recorder().serving(
      "{\"error\":\"unauthorized\"}", status = 401))
    try:
      discard client.getInbox()
      check false
    except HarborError as error:
      check "(HTTP 401)" in error.msg

  test "an answer that is not an inbox raises, never an empty inbox":
    for body in ["[]", "{}", "{\"items\":{}}", "not json"]:
      let client = newHarborClient(base, Recorder().serving(body))
      expect HarborError:
        discard client.getInbox()

suite "moving a cursor":
  test "Next posts to the cursor's next route with what the caller switched to":
    let recorder = Recorder()
    let client = newHarborClient(base, recorder.serving(nextBody), apiKeyAuth("k"))
    let answer = client.moveInboxCursor(DefaultInboxCursor,
      cursorMove(icNext, expectedVersion = 0, landedOn = firstItem))
    let req = recorder.requests[0]
    check req.httpMethod == hmPost
    check req.url == base & "/api/v1/inbox/cursors/default/next"
    check req.headerValue("Content-Type").startsWith("application/json")
    check req.headerValue("Authorization") == "ApiKey k"
    let body = parseJson(req.body)
    check body["expectedVersion"].getInt() == 0
    check body["landedOn"].getStr() == firstItem
    check answer["item"]["id"].getStr() == firstItem
    check answer["cursorVersion"].getInt() == 1
    check answer["ahead"]["basedOn"].getInt() == 1

  test "Prev posts to the prev route; a press with nothing in hand sends an empty object":
    let recorder = Recorder()
    let client = newHarborClient(base, recorder.serving(nextBody))
    discard client.moveInboxCursor("my-tool", cursorMove(icPrev))
    check recorder.requests[0].url == base & "/api/v1/inbox/cursors/my-tool/prev"
    check parseJson(recorder.requests[0].body) == newJObject()

  test "the scope goes in the move's query, and the cursor name is not repeated there":
    let recorder = Recorder()
    let client = newHarborClient(base, recorder.serving(nextBody))
    discard client.moveInboxCursor(DefaultInboxCursor, cursorMove(icNext),
      InboxQuery(cursor: "ignored", orgId: "o"))
    check recorder.requests[0].url == base & "/api/v1/inbox/cursors/default/next?org_id=o"

  test "with nothing waiting the answer's item is null":
    let client = newHarborClient(base, Recorder().serving(emptyMoveBody))
    let answer = client.moveInboxCursor(DefaultInboxCursor, cursorMove(icNext))
    check answer["item"].kind == JNull

  test "a server without cursors answers 404, which raises, never a null item (captured)":
    let client = newHarborClient(base, Recorder().serving(noRouteBody, status = 404))
    try:
      discard client.moveInboxCursor(DefaultInboxCursor, cursorMove(icNext))
      check false
    except HarborError as error:
      check "(HTTP 404)" in error.msg

  test "an answer without item raises":
    for body in ["{}", "[]", "{\"cursorVersion\":3}", "not json"]:
      let client = newHarborClient(base, Recorder().serving(body))
      expect HarborError:
        discard client.moveInboxCursor(DefaultInboxCursor, cursorMove(icNext))

  test "a cursor name the server would refuse is refused before any request":
    let recorder = Recorder()
    let client = newHarborClient(base, recorder.serving(nextBody))
    for name in ["", "Default", "a/b", "a b", repeat('a', 65)]:
      expect HarborError:
        discard client.moveInboxCursor(name, cursorMove(icNext))
      if name.len > 0:   # an empty cursor on a read means "no cursor"
        expect HarborError:
          discard client.getInbox(InboxQuery(cursor: name))
    check recorder.requests.len == 0
    check validCursorName(repeat('a', 64))
    check validCursorName("ci-7")

suite "following the inbox stream":
  test "the stream request and its frames (shape guessed: ahead on each cursors entry)":
    let recorder = Recorder()
    let client = newHarborClient(base, recorder.serving(eventsFeed), bearerAuth("t"))
    var seen: seq[SseFrame] = @[]
    client.followInbox(proc(frame: SseFrame): bool =
      seen.add frame
      true)
    let req = recorder.requests[0]
    check req.url == base & "/api/v1/inbox/events"
    check req.headerValue("Accept") == "text/event-stream"
    check req.headerValue("Authorization") == "Bearer t"
    check req.headerValue("Last-Event-ID") == ""
    check seen.len == 4
    check seen[0].event == "resync"
    check seen[0].id == "3f6c2a9d1e0b4c77:1"
    check parseJson(seen[0].data)["reason"].getStr() == "connected"
    check seen[2].event == "changed"
    let moved = parseJson(seen[2].data)
    check moved["reasons"][0].getStr() == "cursor"
    check moved["cursors"][0]["itemId"].getStr() == firstItem
    check moved["cursors"][0]["ahead"]["next"][0].getStr() == secondItem

  test "a reconnection names the last frame in Last-Event-ID, and the scope goes in the query":
    let recorder = Recorder()
    let client = newHarborClient(base, recorder.serving(eventsFeed))
    client.followInbox(proc(frame: SseFrame): bool = true,
      InboxQuery(cursor: "default", projectId: "p"), lastEventId = "3f6c2a9d1e0b4c77:4")
    check recorder.requests[0].url == base & "/api/v1/inbox/events?project_id=p"
    check recorder.requests[0].headerValue("Last-Event-ID") == "3f6c2a9d1e0b4c77:4"

  test "the consumer stops the stream by returning false":
    let client = newHarborClient(base, Recorder().serving(eventsFeed))
    var count = 0
    client.followInbox(proc(frame: SseFrame): bool =
      inc count
      count < 2)
    check count == 2

  test "a server without the stream answers 404, which raises (as ah 0.6.17 does)":
    let client = newHarborClient(base, Recorder().serving(
      "{\"status\":404,\"detail\":\"API route not found\"}", status = 404))
    expect HarborError:
      client.followInbox(proc(frame: SseFrame): bool = true)
