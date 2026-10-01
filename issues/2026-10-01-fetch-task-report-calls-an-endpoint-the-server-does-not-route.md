# `fetchTaskReport` requests `/api/v1/sessions/{id}/report`, which the Agent Harbor REST server does not route, and hides the failure

| | |
|---|---|
| Status | open |
| Recorded | 2026-10-01 |
| Observed in | nim-agent-harbor @ c1616880 (`src/nim_agent_harbor/client.nim`, `fetchTaskReport`); agent-harbor @ 2338c1ca (`agents`) for the server side |
| Area | REST client, task/session state refresh |

## Observed

`fetchTaskReport(client, sessionId)` sends:

```
GET <baseUrl>/api/v1/sessions/<sessionId>/report
```

The Agent Harbor REST server registers no such route. The session sub-routes
in `crates/ah-rest-server/src/server.rs` are `/sessions/:id` and
`/sessions/:id/{branch, branches, checkpoint, conversation, diff,
domain-approvals, events, files, fs-snapshots, info, input, logs, messages,
model, moments, participants, pause, prompt, pty, recording, resolve-path,
result, resume, sandbox-diff, sandbox-retarget, seek, session-branch, shares,
stash, stop, sudo-approvals, suggestions, summarize, switch-os, terminal,
timeline}`. The only route containing `report` is
`/manager/thinking-assistants/:assistant_id/reports`.

Against a real server, the request therefore gets a non-2xx response. On any
non-2xx status, `fetchTaskReport` returns the minimally populated report with
no error:

```nim
if response.status < 200 or response.status >= 300:
  return
```

The caller then sees a report with an empty `taskId`, `workspacePath`,
`workingCopyMode` and `status`, which looks the same as a session that has no
state yet. The documented consumer is the codetracer ViewModel, which refreshes
per-session entries from this report. It never receives a workspace path or
status, and nothing tells it why.

The test `"reads the latest task report for a session"` passes only because
`src/nim_agent_harbor/fake.nim` answers
`req.url.endsWith("/api/v1/sessions/session-1/report")` with a canned body.
The fake implements an endpoint the server does not have.

## Expected

`agent-harbor/specs/REST-Service/API.md` has no `/sessions/{id}/report`. The
endpoints it specifies for the data `HarborTaskReport` carries are:

- `GET /api/v1/sessions/{id}`: "session details including current status,
  workspace summary, recent events, and change statistics";
- `GET /api/v1/tasks/{id}` and `GET /api/v1/tasks/{id}/sessions`, for the task
  id and its session list.

The client should call an endpoint the spec defines.

Not specified. Proposed: a failed refresh should reach the caller as an error,
or as a report that says it failed. It should not look like an empty but
successful snapshot. The spec does not say how this library reports a
transport failure. `createTask` and `sendPrompt` raise `HarborError` on
non-2xx, so the library's own convention is to raise.

## Evidence

Inferred from code on both sides, not measured. No request was made against a
running server.

```sh
grep -n '/report' nim-agent-harbor/src/nim_agent_harbor/client.nim nim-agent-harbor/src/nim_agent_harbor/fake.nim
grep -rn '"/sessions/:[a-z_]*/[a-z_-]*"' agent-harbor/crates/ah-rest-server/src --include=*.rs | grep -c report   # 0
grep -n '/report' agent-harbor/specs/REST-Service/API.md   # only .../thinking-assistants/{assistantId}/reports
```

## Suggested direction

Read the report from `GET /api/v1/sessions/{id}`, or from `/info` if the
fields live there, and map that response's field names onto
`HarborTaskReport`. Raise `HarborError` on non-2xx, as the other calls do.

Change the fake to answer the real path with a body captured from a real
server, so the fake cannot keep an endpoint the server does not have. A test
against a real `ah-rest-server` would settle both this issue and the
authentication-header issue below.

## Related

- `issues/2026-10-01-api-key-auth-sends-a-header-the-server-rejects.md`: the
  same pattern, where the canned transport accepts what the real server would
  reject.
- Archive search: this repository has one other issue and no resolved ones
  (`git log --diff-filter=D -- issues/` is empty).
