## Listing sessions and following the session lifecycle feed against a real
## Agent Harbor REST server, over the library's native transports.
##
## `test_session_fleet.nim` pins the requests and the reading of captured
## responses; this test proves the same calls against the server itself. It
## starts `ah server start` (see `nim_agent_harbor/testing/real_server.nim`)
## with authentication on, and checks that:
##
## - the list and the feed both need the client's credentials;
## - an empty server lists no sessions;
## - a feed opened without a cursor starts with `resync` (`no_cursor`), and a
##   session created while it is open arrives as `session_created` and then
##   its later frames, each with an `<epoch>-<seq>` cursor;
## - the listing then holds that session;
## - resuming from the first cursor replays exactly the later frames and ends
##   with `caught_up`, whose `replayed` counts them;
## - negative controls: a cursor from another epoch yields `resync`
##   (`unknown_epoch`) first, and a malformed one `resync` (`invalid_cursor`).
##
## When no `ah` binary is available the test is skipped with the reason
## printed, so hosts without Agent Harbor stay green. Native only.

import std/[json, os, osproc, strutils]
import unittest
import nim_everywhere
import nim_agent_harbor
import nim_agent_harbor/testing/real_server

const apiKey = "nim-agent-harbor-fleet-key"

proc liveClient(server: RealServer; auth: HarborAuth): HarborClient =
  result = newNativeHarborClient(server.baseUrl, auth)
  # A short read deadline, so a feed that stops sending fails the test
  # instead of holding it for the library's 30-minute default.
  result.frameStreamTransport = nativeHarborFrameStream(timeoutMs = 20_000)

proc firstFrame(client: HarborClient; after: string): SseFrame =
  var frames: seq[SseFrame] = @[]
  client.followSessionLifecycle(proc(frame: SseFrame): bool =
    frames.add frame
    false, after = after)
  doAssert frames.len == 1, "the feed closed before its first frame"
  frames[0]

proc gitRepo(dir: string) =
  createDir(dir)
  for args in [@["init", "-q", "-b", "main", dir],
      @["-C", dir, "-c", "user.name=fleet", "-c", "user.email=fleet@example.invalid",
        "commit", "-q", "--allow-empty", "-m", "init"]]:
    let p = startProcess("git", args = args, options = {poUsePath, poParentStreams})
    doAssert p.waitForExit() == 0, "git " & args.join(" ")
    p.close()

suite "real ah-rest-server session list and lifecycle feed":
  let binary = serverBinary()

  test "list, follow, resume and resync":
    if binary.len == 0:
      echo "SKIPPED: no Agent Harbor server binary: `ah` is not on PATH and " &
        "AH_SERVER_BIN is unset"
      skip()
    else:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      let client = server.liveClient(apiKeyAuth(apiKey))

      let anonymous = server.liveClient(HarborAuth(kind: akNone))
      try:
        discard anonymous.listSessions()
        check false
      except HarborError as error:
        check "401" in error.msg
      expect HarborError:
        discard anonymous.firstFrame("")

      let empty = client.listSessions()
      check empty.items.len == 0
      check empty.total == 0

      let repoDir = server.root / "repo"
      gitRepo(repoDir)
      # The task is created from inside the feed's callback, through an
      # independent blocking transport: the feed's own client is busy
      # reading the stream.
      let creator = newHarborClient(server.baseUrl, nativeTransport(),
        apiKeyAuth(apiKey))
      var sessionId = ""
      var frames: seq[SseFrame] = @[]
      client.followSessionLifecycle(proc(frame: SseFrame): bool =
        frames.add frame
        if frames.len == 1:
          let created = creator.createTask(probeTask(repoDir, "fleet probe"))
          doAssert created.sessionIds.len == 1
          sessionId = created.sessionIds[0]
          return true
        let data = parseJson(frame.data)
        # Stop at the session's terminal frame, or give up after a bound
        # that a session failing at workspace preparation never reaches.
        not (data{"kind"}.getStr() == "session_completed" and
          data{"sessionId"}.getStr() == sessionId) and frames.len < 50)

      check frames[0].event == "resync"
      check frames[0].id == ""
      check parseJson(frames[0].data)["reason"].getStr() == "no_cursor"
      let lifecycle = frames[1 .. ^1]
      check lifecycle.len >= 2
      var kinds: seq[string] = @[]
      for frame in lifecycle:
        check frame.event == "lifecycle"
        check frame.id.split('-').len == 2
        let data = parseJson(frame.data)
        check data["sessionId"].getStr() == sessionId
        kinds.add data["kind"].getStr()
      check kinds[0] == "session_created"
      check kinds[^1] == "session_completed"

      let listed = client.listSessions()
      check listed.total == 1
      check listed.items.len == 1
      check listed.items[0]["id"].getStr() == sessionId
      check listed.items[0]["status"].getStr() ==
        parseJson(lifecycle[^1].data)["status"].getStr()

      var replay: seq[SseFrame] = @[]
      client.followSessionLifecycle(proc(frame: SseFrame): bool =
        replay.add frame
        frame.event != "caught_up" and replay.len < 50, after = lifecycle[0].id)
      check replay.len == lifecycle.len
      check replay[^1].event == "caught_up"
      check parseJson(replay[^1].data)["replayed"].getInt() == lifecycle.len - 1
      check parseJson(replay[^1].data)["cursor"].getStr() == lifecycle[^1].id
      for i in 0 ..< replay.len - 1:
        check replay[i].id == lifecycle[i + 1].id

      let epoch = lifecycle[0].id.split('-')[0]
      let otherEpoch = (if epoch == "0000000000000000": "1111111111111111"
                        else: "0000000000000000") & "-1"
      let other = client.firstFrame(otherEpoch)
      check other.event == "resync"
      check parseJson(other.data)["reason"].getStr() == "unknown_epoch"
      let malformed = client.firstFrame("not-a-cursor")
      check malformed.event == "resync"
      check parseJson(malformed.data)["reason"].getStr() == "invalid_cursor"
