# Session snapshot fixture

`src/nim_agent_harbor/fixtures/session.json` is the response to an authenticated
`GET /api/v1/sessions/{id}`
after the task creation in `test_real_server_auth.nim`. Captured on
2026-10-18 on nixos-ci-bare-004 using
`/nix/store/7vxr9sdgiygg8944i0dcp6sk726gcgpk-agent-harbor-cli-0.1.0/bin/ah`
(`ah 0.6.12-dev`). The installed binary's source revision is not embedded in
its version; the session wire structure was also checked against Agent Harbor
`0901423e2eb5ae6b7f0728d93a22a4cfbc4a57f6`.

Only the generated session ID, temporary workspace path, repository URL, and
links containing that ID have been normalized. The fixture intentionally has
neither a task ID nor a sibling session list: the real session response does
not provide them. The fake uses this captured response to isolate parsing and
HTTP error handling from live server and agent lifecycle timing. The native
real-server test separately verifies the actual route and response fields.

# Fleet fixtures

`tests/fixtures/fleet/` holds the responses `test_session_fleet.nim` reads:

| File | Request |
| --- | --- |
| `sessions-empty.json` | `GET /api/v1/sessions` on a server with no sessions |
| `sessions.json` | `GET /api/v1/sessions` after one task was created |
| `lifecycle-live.sse` | `GET /api/v1/session-lifecycle/events`, opened before that task was created: `resync` (`no_cursor`), then the session's `session_created`, `session_status_changed` and `session_completed` |
| `lifecycle-replay.sse` | the feed with `?after=` the first frame's cursor: the two later frames, then `caught_up` |
| `lifecycle-other-epoch.sse` | the feed with `?after=0000000000000000-1`: `resync` (`unknown_epoch`) |

Captured on 2026-11-27 on a Linux workstation from a private `ah server start`
(fresh `HOME` and XDG directories, no authentication, loopback port), using
`/nix/store/gk6iq1vzw2daknrp4lldn2xcsrrqln3g-agent-harbor-cli-0.6.17/bin/ah`
(`ah 0.6.17-dev`). The task was the one `real_ah_server.nim`'s `probeTask`
builds (an ACP agent whose launch command is `true`), so the session fails
at workspace preparation; that is enough to produce its whole lifecycle.

Normalized: the session ID, the temporary repository path, and the host name
in `handle`. Two free-text values that quote the server's internal log, the
workspace error and `startingPointFallbackReason`, are replaced by
`(redacted)` text; the tests read neither. The SSE files are the decoded
stream body: the HTTP chunk-size lines of the raw socket read were removed,
and the open stream was cut after its last frame. `test_real_server_fleet.nim`
checks the same calls against a live server.
