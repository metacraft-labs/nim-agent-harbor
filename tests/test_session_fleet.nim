## The fleet calls a front-end needs to list sessions and follow their
## lifecycle: `GET /api/v1/sessions` and `GET /api/v1/session-lifecycle/events`.
##
## The HTTP peer here is a recording closure that answers with responses
## captured from a real `ah server` (`tests/fixtures/fleet/`, provenance in
## `tests/fixtures/README.md`). It is justified because these cases pin the
## request each call sends (path, query, headers) and how each captured body
## is read, deterministically and on both the native and the JS backend; a
## live server can do neither. The same calls against the live server, over
## the native streaming transport, are `test_real_server_fleet.nim`.
import std/[json, sequtils, strutils]
import unittest
import nim_everywhere
import nim_agent_harbor

const
  base = "http://127.0.0.1:18081"
  sessionsBody = staticRead("fixtures/fleet/sessions.json")
  sessionsEmptyBody = staticRead("fixtures/fleet/sessions-empty.json")
  liveFeed = staticRead("fixtures/fleet/lifecycle-live.sse")
  replayFeed = staticRead("fixtures/fleet/lifecycle-replay.sse")
  otherEpochFeed = staticRead("fixtures/fleet/lifecycle-other-epoch.sse")
  capturedId = "5a7e0c1d-0000-4000-8000-00000000f1ee"

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

suite "SSE frames":
  test "a captured live feed reads as its four frames":
    let frames = parseSseFrames(liveFeed)
    check frames.len == 4
    check frames[0].event == "resync"
    check frames[0].id == ""
    check parseJson(frames[0].data)["reason"].getStr() == "no_cursor"
    var kinds: seq[string] = @[]
    for frame in frames[1 .. ^1]:
      check frame.event == "lifecycle"
      kinds.add parseJson(frame.data)["kind"].getStr()
    check kinds == @["session_created", "session_status_changed", "session_completed"]
    check frames[1].id == "ec97071de8b44550-1"
    check frames[3].id == "ec97071de8b44550-3"

  test "the event-stream format: CRLF, comments, joined data, one space, no event name":
    # https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation
    let text = ": keep-alive\r\n" &
      "event: lifecycle\r\nid: e-7\r\ndata:  two spaces\r\ndata:second\r\n\r\n" &
      "data\n\n" &
      "id: lone-id\n\n" &
      "data: {\"a\":1}\n\n" &
      "event: caught_up\ndata: unterminated"
    let frames = parseSseFrames(text)
    check frames.len == 3
    check frames[0].event == "lifecycle"
    check frames[0].id == "e-7"
    # Only the one space after the colon is removed; repeated data lines
    # join with a newline.
    check frames[0].data == " two spaces\nsecond"
    # A bare `data` field is an empty data line, which still dispatches.
    check frames[1].event == "message"
    check frames[1].data == ""
    # A block with an id and no data dispatches nothing, and its id does not
    # carry into the next frame's `id`.
    check frames[2].data == "{\"a\":1}"
    check frames[2].id == ""
    # The last block has no closing blank line, so it is not an event yet.

  test "a reader fed line by line yields the same frames as the whole text":
    var reader = initSseReader()
    var frames: seq[SseFrame] = @[]
    for line in replayFeed.splitLines:
      var frame: SseFrame
      if reader.feedLine(line, frame): frames.add frame
    check frames == parseSseFrames(replayFeed)
    check frames.len == 3

suite "listing sessions":
  test "the list request and the captured listing":
    let recorder = Recorder()
    let client = newHarborClient(base & "/", recorder.answering(
      proc(req: HttpRequest): HttpResponse = ok(sessionsBody)), bearerAuth("tok"))
    let page = client.listSessions()
    check recorder.requests.len == 1
    let req = recorder.requests[0]
    check req.httpMethod == hmGet
    check req.url == base & "/api/v1/sessions"
    check req.headerValue("Accept") == "application/json"
    check req.headerValue("Authorization") == "Bearer tok"
    check page.items.len == 1
    check page.items[0]["id"].getStr() == capturedId
    check page.total == 1
    # Today's server names no next page when everything fits.
    check page.nextPage == 0

  test "an empty server lists nothing":
    let client = newHarborClient(base, Recorder().answering(
      proc(req: HttpRequest): HttpResponse = ok(sessionsEmptyBody)))
    let page = client.listSessions()
    check page.items.len == 0
    check page.total == 0
    check page.nextPage == 0

  test "filters and paging go in the query":
    let recorder = Recorder()
    let client = newHarborClient(base, recorder.answering(
      proc(req: HttpRequest): HttpResponse = ok(sessionsEmptyBody)))
    discard client.listSessions(SessionListQuery(status: "running", page: 2, perPage: 50))
    check recorder.requests[0].url == base & "/api/v1/sessions?status=running&page=2&perPage=50"

  test "a refused list raises and names the status":
    let client = newHarborClient(base, Recorder().answering(
      proc(req: HttpRequest): HttpResponse =
        HttpResponse(status: 401, body: "{\"error\":\"unauthorized\"}")))
    try:
      discard client.listSessions()
      check false
    except HarborError as error:
      check "401" in error.msg

  test "a listing that is not a page object raises":
    for body in ["[]", "{\"total\":1}", "{\"items\":{}}"]:
      let client = newHarborClient(base, Recorder().answering(
        proc(req: HttpRequest): HttpResponse = ok(body)))
      expect HarborError:
        discard client.listSessions()

  test "listing every session follows nextPage":
    let recorder = Recorder()
    let client = newHarborClient(base, recorder.answering(
      proc(req: HttpRequest): HttpResponse =
        if "page=1&" in req.url:
          ok($(%*{"items": [{"id": "a"}], "total": 2, "nextPage": 2}))
        else:
          ok($(%*{"items": [{"id": "b"}], "total": 2, "nextPage": nil}))))
    let sessions = client.listAllSessions()
    var ids: seq[string] = @[]
    for item in sessions: ids.add item["id"].getStr()
    check ids == @["a", "b"]
    check recorder.requests.len == 2
    check recorder.requests[0].url == base & "/api/v1/sessions?page=1&perPage=200"
    check recorder.requests[1].url == base & "/api/v1/sessions?page=2&perPage=200"

  test "nextPage as the server sends it, a path, is followed":
    # The shape of a real ah server's page (ah 0.6.17-dev, 2026-11-27):
    # `nextPage` is the next page's path, not its number.
    let recorder = Recorder()
    let client = newHarborClient(base, recorder.answering(
      proc(req: HttpRequest): HttpResponse =
        if "page=1&" in req.url:
          ok($(%*{"items": [{"id": "a"}], "total": 3,
                  "nextPage": "/api/v1/sessions?page=2&perPage=200"}))
        elif "page=2&" in req.url:
          ok($(%*{"items": [{"id": "b"}], "total": 3,
                  "nextPage": "/api/v1/sessions?status=completed&page=3&perPage=200"}))
        else:
          ok($(%*{"items": [{"id": "c"}], "total": 3}))))
    let ids = client.listAllSessions().mapIt(it["id"].getStr())
    check ids == @["a", "b", "c"]
    check recorder.requests.len == 3
    check recorder.requests[2].url == base & "/api/v1/sessions?page=3&perPage=200"
    check sessionListPageFromJson(%*{"items": [], "total": 0,
      "nextPage": "/api/v1/sessions?perPage=50&page=7"}).nextPage == 7

  test "a nextPage path naming no page raises rather than reading as the last page":
    let client = newHarborClient(base, Recorder().answering(
      proc(req: HttpRequest): HttpResponse =
        ok($(%*{"items": [{"id": "a"}], "total": 2,
                "nextPage": "/api/v1/sessions?cursor=opaque"}))))
    expect HarborError:
      discard client.listAllSessions()

  test "a nextPage that does not advance raises instead of looping":
    let client = newHarborClient(base, Recorder().answering(
      proc(req: HttpRequest): HttpResponse =
        ok($(%*{"items": [{"id": "a"}], "total": 9, "nextPage": 1}))))
    expect HarborError:
      discard client.listAllSessions()

suite "following the lifecycle feed":
  test "a cursor resumes through ?after= and the replay ends with caught_up":
    let recorder = Recorder()
    let client = newHarborClient(base, recorder.answering(
      proc(req: HttpRequest): HttpResponse = ok(replayFeed)), apiKeyAuth("k"))
    var seen: seq[SseFrame] = @[]
    client.followSessionLifecycle(proc(frame: SseFrame): bool =
      seen.add frame
      true, after = "ec97071de8b44550-1")
    let req = recorder.requests[0]
    check req.url == base & "/api/v1/session-lifecycle/events?after=ec97071de8b44550-1"
    check req.headerValue("Accept") == "text/event-stream"
    check req.headerValue("Authorization") == "ApiKey k"
    check seen.len == 3
    check seen[0].id == "ec97071de8b44550-2"
    check seen[2].event == "caught_up"
    check parseJson(seen[2].data)["replayed"].getInt() == 2

  test "no cursor sends no after parameter":
    let recorder = Recorder()
    let client = newHarborClient(base, recorder.answering(
      proc(req: HttpRequest): HttpResponse = ok(liveFeed)))
    client.followSessionLifecycle(proc(frame: SseFrame): bool = true)
    check recorder.requests[0].url == base & "/api/v1/session-lifecycle/events"

  test "a cursor from another epoch yields resync first":
    let client = newHarborClient(base, Recorder().answering(
      proc(req: HttpRequest): HttpResponse = ok(otherEpochFeed)))
    var seen: seq[SseFrame] = @[]
    client.followSessionLifecycle(proc(frame: SseFrame): bool =
      seen.add frame
      true, after = "0000000000000000-1")
    check seen.len >= 1
    check seen[0].event == "resync"
    check parseJson(seen[0].data)["reason"].getStr() == "unknown_epoch"

  test "the consumer stops the feed by returning false":
    let client = newHarborClient(base, Recorder().answering(
      proc(req: HttpRequest): HttpResponse = ok(liveFeed)))
    var count = 0
    client.followSessionLifecycle(proc(frame: SseFrame): bool =
      inc count
      count < 2)
    check count == 2

  test "a streaming transport, when set, carries the feed":
    let recorder = Recorder()
    var client = newHarborClient(base, recorder.answering(
      proc(req: HttpRequest): HttpResponse = ok("")))
    var streamed: seq[HttpRequest] = @[]
    client.frameStreamTransport = proc(req: HttpRequest; onFrame: HarborFrameCallback) =
      streamed.add req
      for frame in parseSseFrames(replayFeed):
        if not onFrame(frame): return
    var seen = 0
    client.followSessionLifecycle(proc(frame: SseFrame): bool =
      inc seen
      true, after = "e-1")
    check recorder.requests.len == 0
    check streamed.len == 1
    check streamed[0].url == base & "/api/v1/session-lifecycle/events?after=e-1"
    check seen == 3

  test "a refused feed raises and names the status":
    let client = newHarborClient(base, Recorder().answering(
      proc(req: HttpRequest): HttpResponse =
        HttpResponse(status: 501, body: "no journal")))
    try:
      client.followSessionLifecycle(proc(frame: SseFrame): bool = true)
      check false
    except HarborError as error:
      check "501" in error.msg
