# Session state refresh

> **Status:** ✓ Implemented

`fetchTaskReport(client, sessionId)` reads the authenticated
`GET /api/v1/sessions/{sessionId}` endpoint. It never requests a `/report`
sub-route. The returned `HarborTaskReport` is a session snapshot:

| Report field | Session response field |
| --- | --- |
| `sessionIds` | The requested session ID, as a one-element sequence |
| `workspacePath` | `workspace.mountPath` |
| `workingCopyMode` | `workspace.snapshotProvider` |
| `status` | `status` |
| `raw` | The complete parsed session response |

The server retains the requested working-copy mode in `snapshotProvider` and
also exposes it as `working_copy_mode` on the session `/info` endpoint.
The session endpoint does not supply an orchestration task ID or sibling
session list; `taskId` is empty. Callers needing task membership must use the
task API and retain its task ID.

Every non-2xx response raises `HarborError` containing the HTTP status and
response body, including authentication, missing-session, and server errors.
A failed refresh must not produce an empty successful report. Transport and
JSON parsing exceptions propagate to the caller. A successful response can
omit workspace data while provisioning; absent optional strings remain empty.

## Implementation

[`client.nim`](../src/nim_agent_harbor/client.nim) implements the request and
mapping. [`fake.nim`](../src/nim_agent_harbor/fake.nim) serves the captured
session response on the canonical route.

## Key Integration Tests

[`test_real_server_auth.nim`](../tests/test_real_server_auth.nim) creates a
task on a real authenticated server, verifies the session endpoint succeeds
while `/report` returns 404, and checks refresh fields and missing-session
errors. Set `AH_SERVER_BIN` to the server executable when validating this
contract so the test executes.

[`test_agent_harbor.nim`](../tests/test_agent_harbor.nim) checks captured session
parsing on native and JavaScript targets, preserves raw data, and verifies
authentication, missing-session, server, and transport failures are visible.
