import std/json
import std/strutils
import nim_everywhere

# Captured from a real ah server; see tests/fixtures/README.md. This fixture
# keeps the fake on the server's actual session route and nested wire shape.
const sessionSnapshot = staticRead("fixtures/session.json")

proc hasApiKey(req: HttpRequest; apiKey: string): bool =
  for item in req.headers:
    if item.name.cmpIgnoreCase("Authorization") == 0 and
        item.value == "ApiKey " & apiKey:
      return true

proc fakeHarborTransport*(apiKey = ""): HttpTransport =
  ## With `apiKey` set, the fake enforces authentication as `ah-rest-server`
  ## does when started with an API key: a request without
  ## `Authorization: ApiKey <apiKey>` gets 401. Other headers, `X-API-Key`
  ## among them, are ignored.
  proc(req: HttpRequest): HttpResponse =
    if apiKey.len > 0 and not req.hasApiKey(apiKey):
      return HttpResponse(status: 401, body: $(%*{
        "error": "unauthorized",
        "message": "Missing or invalid Authorization header"
      }))
    if req.httpMethod == hmPost and req.url.endsWith("/api/v1/tasks"):
      return HttpResponse(status: 201, body: $(%*{
        "task_id": "task-1",
        "session_ids": ["session-1"],
        "status": "queued",
        "links": {
          "self": "/api/v1/sessions/session-1",
          "events": "/api/v1/sessions/session-1/events",
          "logs": "/api/v1/sessions/session-1/logs"
        }
      }))
    if req.httpMethod == hmPost and req.url.endsWith("/prompt"):
      return HttpResponse(status: 202, body: $(%*{
        "sessionId": "session-1",
        "accepted": true,
        "ts": "2026-05-04T00:00:00Z"
      }))
    if req.httpMethod == hmGet and req.url.contains("/api/v1/sessions/session-1/events/history"):
      return HttpResponse(status: 200, body: $(%*{
        "events": [
          {"type": "file_edit", "file_path": "src/app.nim", "lines_added": 5, "lines_removed": 1, "timestamp": 1714300003},
          {"type": "tool_result", "tool_name": "nim", "tool_execution_id": "tool-1", "status": "completed", "timestamp": 1714300002}
        ],
        "has_more": false,
        "oldest_timestamp": 1714300002,
        "total_count": 2
      }))
    if req.httpMethod == hmGet and
        req.url.endsWith("/api/v1/sessions/session-1"):
      return HttpResponse(status: 200, body: sessionSnapshot)
    if req.httpMethod == hmGet and req.url.contains("/api/v1/sessions/session-1/events"):
      return HttpResponse(status: 200, body:
        "event: message\n" &
        "data: {\"type\":\"workspace\",\"status\":\"provisioning\",\"workingCopyMode\":\"overlay\",\"provider\":\"agentfs\",\"ts\":\"2026-05-04T00:00:00Z\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"workspace\",\"status\":\"ready\",\"mountPath\":\"/tmp/ah-workspace\",\"workingCopyMode\":\"overlay\",\"provider\":\"agentfs\",\"ts\":\"2026-05-04T00:00:01Z\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"thought\",\"thought\":\"Inspecting files\",\"ts\":\"2026-05-04T00:00:02Z\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"tool_use\",\"tool_name\":\"nim\",\"tool_execution_id\":\"tool-1\",\"status\":\"started\",\"ts\":\"2026-05-04T00:00:03Z\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"delivery\",\"mode\":\"pr\",\"url\":\"https://example.invalid/pr/1\",\"ts\":\"2026-05-04T00:00:04Z\"}\n\n")
    HttpResponse(status: 404, body: "not found")
