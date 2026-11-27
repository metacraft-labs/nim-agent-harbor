## Authentication and session refresh against a real Agent Harbor REST server.
##
## The fake transport in `nim_agent_harbor/fake.nim` only models the header
## contract; this test proves it against the server itself. It starts
## `ah server start` (see `real_ah_server.nim`) with `AH_API_KEY` set, which
## turns REST authentication on, and checks that:
##
## - the client's `apiKeyAuth` creates a task (201);
## - `X-API-Key: <key>`, the header earlier client versions sent, gets 401;
## - a request without credentials, or with `Authorization: ApiKey` and the
##   wrong key, gets 401, so the server really enforces auth and checks the key.
## - session refresh uses the canonical session route and nested workspace
##   fields; the nonexistent /report route gets 404 and missing sessions raise.
##
## When no `ah` binary is available the test is skipped with the reason
## printed, so hosts without Agent Harbor stay green. Native only: it spawns a
## process and talks plain HTTP.

import std/[json, os, strutils]
import unittest
import nim_everywhere
import nim_agent_harbor
import ./real_ah_server

const apiKey = "nim-agent-harbor-test-key"

suite "real ah-rest-server authentication and session refresh":
  let binary = serverBinary()

  test "authenticated task creation and canonical session refresh":
    if binary.len == 0:
      echo "SKIPPED: no Agent Harbor server binary: `ah` is not on PATH and " &
        "AH_SERVER_BIN is unset"
      skip()
    else:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      let repoDir = server.root / "repo"
      createDir(repoDir)
      let body = $taskToJson(probeTask(repoDir, "authentication probe"))
      let jsonHeader = header("Content-Type", "application/json; charset=utf-8")
      let transport = nativeTransport()
      let tasksUrl = server.baseUrl & "/api/v1/tasks"

      proc checkRejected(response: HttpResponse) =
        check response.status == 401
        check "task_id" notin response.body
        check "session_ids" notin response.body

      checkRejected transport.request(newRequest(hmPost, tasksUrl, body,
        @[jsonHeader]))
      checkRejected transport.request(newRequest(hmPost, tasksUrl, body,
        @[jsonHeader, header("X-API-Key", apiKey)]))
      checkRejected transport.request(newRequest(hmPost, tasksUrl, body,
        @[jsonHeader, header("Authorization", "ApiKey wrong-" & apiKey)]))

      var statuses: seq[int] = @[]
      let recording: HttpTransport = proc(req: HttpRequest): HttpResponse =
        result = transport.request(req)
        statuses.add result.status
      let client = newHarborClient(server.baseUrl, recording, apiKeyAuth(apiKey))
      let created = client.createTask(probeTask(repoDir, "authentication probe"))
      check statuses == @[201]
      check created.taskId.len > 0
      check created.sessionIds.len == 1

      let sessionId = created.sessionIds[0]
      let sessionUrl = server.baseUrl & "/api/v1/sessions/" & sessionId
      let headers = @[header("Authorization", "ApiKey " & apiKey)]
      let details = transport.request(newRequest(hmGet, sessionUrl, "", headers))
      check details.status == 200
      let snapshot = parseJson(details.body)
      let missingRoute = transport.request(newRequest(hmGet,
        sessionUrl & "/report", "", headers))
      check missingRoute.status == 404
      statuses.setLen(0)
      let report = client.fetchTaskReport(sessionId)
      check statuses == @[200]
      check report.sessionIds == @[sessionId]
      check report.workspacePath == snapshot{"workspace", "mountPath"}.getStr()
      check report.workspacePath.len > 0
      check report.workingCopyMode == snapshot{"workspace", "snapshotProvider"}.getStr()
      check report.workingCopyMode.len > 0
      check report.status.len > 0
      check report.raw{"id"}.getStr() == sessionId
      expect HarborError:
        discard client.fetchTaskReport("missing-session")
