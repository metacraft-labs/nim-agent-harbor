## A session's event history and its event stream against a real Agent Harbor
## REST server, over the library's native transports: what an activity view
## reads to show one session, and follows to keep it live.
##
## It starts `ah server start` (`nim_agent_harbor/testing/real_server.nim`)
## with authentication on, runs one probe task to its end, and checks that:
##
## - the history (`GET /api/v1/sessions/{id}/events/history`) and the stream
##   (`GET /api/v1/sessions/{id}/events`) both need the client's credentials;
## - the stream opened without a cursor replays the whole history, frame by
##   frame the history's events oldest first (the same type and timestamp),
##   and the history counts exactly those (`total_count`);
## - only a connection's first frame may lack an id, and the ids after it
##   are consecutive;
## - a page (`limit`) holds the newest events and says there are more;
## - resuming the stream after an id sends, as its first frame with an id,
##   the event after that id, never one before it.
##
## What a reader may rely on is only that: it counts the replay against the
## history's `total_count` and drops a frame without an id on a resume. The
## ids themselves are not positions: measured 2026-11-27, a session of the
## operator's running daemon starts with an event that has no id (so its
## event at position p is id p - 1) and resends the cursor's event without
## an id on a resume, while a fresh server's probe session numbers its events
## from 1 and resends nothing. This test runs on the fresh server; the
## server's API description says neither.
##
## When no `ah` binary is available the test is skipped with the reason
## printed, so hosts without Agent Harbor stay green. Native only.

import std/[json, os, osproc, strutils]
import unittest
import nim_agent_harbor
import nim_agent_harbor/testing/real_server

const apiKey = "nim-agent-harbor-events-key"

proc liveClient(server: RealServer; auth: HarborAuth): HarborClient =
  result = newNativeHarborClient(server.baseUrl, auth)
  # A short read deadline: an ended session's stream sends nothing after its
  # replay, and the reads below stop by count before it expires.
  result.frameStreamTransport = nativeHarborFrameStream(timeoutMs = 20_000)

proc gitRepo(dir: string) =
  createDir(dir)
  for args in [@["init", "-q", "-b", "main", dir],
      @["-C", dir, "-c", "user.name=events", "-c", "user.email=events@example.invalid",
        "commit", "-q", "--allow-empty", "-m", "init"]]:
    let p = startProcess("git", args = args, options = {poUsePath, poParentStreams})
    doAssert p.waitForExit() == 0, "git " & args.join(" ")
    p.close()

proc runProbeToItsEnd(client, creator: HarborClient; repoDir: string): string =
  ## Creates a probe task and follows the lifecycle feed until its session
  ## completes; returns the session's id.
  var sessionId = ""
  var frames = 0
  client.followSessionLifecycle(proc(frame: SseFrame): bool =
    inc frames
    if frames == 1:
      let created = creator.createTask(probeTask(repoDir, "events probe"))
      doAssert created.sessionIds.len == 1
      sessionId = created.sessionIds[0]
      return true
    let data = parseJson(frame.data)
    not (data{"kind"}.getStr() == "session_completed" and
      data{"sessionId"}.getStr() == sessionId) and frames < 50)
  sessionId

proc readFrames(client: HarborClient; sessionId: string; count: int;
                after = ""): seq[SseFrame] =
  ## The stream's first `count` frames.
  var frames: seq[SseFrame] = @[]
  client.followSessionEvents(sessionId, proc(frame: SseFrame): bool =
    frames.add frame
    frames.len < count, after = after)
  frames

proc key(event: JsonNode): string =
  ## What identifies an event across the two reads: its type and timestamp.
  event{"type"}.getStr() & "@" & $event{"timestamp"}.getBiggestInt()

suite "real ah-rest-server session event history and stream":
  let binary = serverBinary()

  test "history and stream agree, and the stream resumes after an id":
    if binary.len == 0:
      echo "SKIPPED: no Agent Harbor server binary: `ah` is not on PATH and " &
        "AH_SERVER_BIN is unset"
      skip()
    else:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      let client = server.liveClient(apiKeyAuth(apiKey))
      let creator = newHarborClient(server.baseUrl, nativeTransport(),
        apiKeyAuth(apiKey))
      let repoDir = server.root / "repo"
      gitRepo(repoDir)
      let sessionId = runProbeToItsEnd(client, creator, repoDir)
      check sessionId.len > 0

      # Credentials: both reads are refused without them.
      let anonymous = server.liveClient(HarborAuth(kind: akNone))
      expect HarborError:
        discard anonymous.readEventHistoryJson(sessionId)
      expect HarborError:
        discard anonymous.readFrames(sessionId, 1)

      # A session can still add an event (a final `status`) after its
      # lifecycle says it completed: wait until its history stops growing,
      # so both reads below see the same events.
      var history = client.readEventHistoryJson(sessionId, limit = 200)
      for _ in 0 ..< 20:
        sleep(500)
        let again = client.readEventHistoryJson(sessionId, limit = 200)
        if again["total_count"].getInt() == history["total_count"].getInt():
          break
        history = again
      let total = history["total_count"].getInt()
      let events = history["events"]
      echo "probe session: ", total, " events in its history"
      check total >= 3
      check events.len == total          # the probe's history fits a page
      check not history["has_more"].getBool()

      # The whole replay, frame by frame the history oldest first. Only the
      # first frame may lack an id; the ids after it are consecutive.
      let replay = client.readFrames(sessionId, total)
      check replay.len == total
      var oldestFirst: seq[JsonNode] = @[]
      for i in countdown(events.len - 1, 0): oldestFirst.add events[i]
      for p in 0 ..< min(total, replay.len):
        check key(parseJson(replay[p].data)) == key(oldestFirst[p])
      var last = -1
      for p in 0 ..< replay.len:
        if replay[p].id.len == 0:
          check p == 0
          continue
        let id = parseInt(replay[p].id)
        if last >= 0: check id == last + 1
        last = id

      # A page holds the newest events and says there are more.
      let page = client.readEventHistoryJson(sessionId, limit = 2)
      check page["events"].len == 2
      check page["has_more"].getBool()
      check page["total_count"].getInt() == total
      check key(page["events"][0]) == key(oldestFirst[^1])

      # Resuming after the next-to-last id: the first frame with an id is
      # the last event, never one the caller already applied. A frame
      # without an id may come first (a running daemon resends the event
      # named by the cursor that way); a reader drops it.
      let cursor = replay[^2].id
      check cursor.len > 0
      var resumed: seq[SseFrame] = @[]
      client.followSessionEvents(sessionId, proc(frame: SseFrame): bool =
        resumed.add frame
        frame.id.len == 0 and resumed.len < 3, after = cursor)
      var firstWithId = -1
      for i, frame in resumed:
        if frame.id.len > 0:
          firstWithId = i
          break
        check i == 0
      check firstWithId >= 0
      if firstWithId >= 0:
        check resumed[firstWithId].id == replay[^1].id
        check key(parseJson(resumed[firstWithId].data)) == key(oldestFirst[^1])
