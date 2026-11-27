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
(`ah 0.6.17-dev`). The task was the one `probeTask` in
`src/nim_agent_harbor/testing/real_server.nim` builds (an ACP agent whose
launch command is `true`), so the session fails at workspace preparation;
that is enough to produce its whole lifecycle.

Normalized: the session ID, the temporary repository path, and the host name
in `handle`. Two free-text values that quote the server's internal log, the
workspace error and `startingPointFallbackReason`, are replaced by
`(redacted)` text; the tests read neither. The SSE files are the decoded
stream body: the HTTP chunk-size lines of the raw socket read were removed,
and the open stream was cut after its last frame. `test_real_server_fleet.nim`
checks the same calls against a live server.

# Inbox fixtures

`tests/fixtures/inbox/` holds the answers `test_inbox.nim` reads. Two were
captured; the rest are **shaped from the REST contract, not captured**,
because no server serves the inbox stream or the cursors yet:

| File | Request | Provenance |
| --- | --- | --- |
| `inbox-empty.json` | `GET /api/v1/inbox` on a server with no sessions | captured |
| `cursor-no-route.json` | `POST /api/v1/inbox/cursors/default/next` on a server without cursors (404) | captured |
| `inbox-cursor.json` | `GET /api/v1/inbox?cursor=default` with three items waiting and a fresh cursor | shaped |
| `cursor-next.json` | the first Next on that cursor | shaped |
| `cursor-empty.json` | a move with nothing waiting | shaped |
| `inbox-events.sse` | `GET /api/v1/inbox/events`: `resync`, then `changed` for an item entering, a cursor move and an item leaving | shaped |

The captures were made on 2026-11-27 on a Linux workstation from a private
`ah server start`, as above, using
`/nix/store/855k6na6kfa0lcrj95nsb6m13f59xbsy-agent-harbor-cli-0.6.17/bin/ah`
(`ah 0.6.17-dev`, a different build from the fleet captures' under the same
version string); that build answers `GET /api/v1/inbox/events` with 404
too. Only `generatedAt` varies between runs.

The shaped files follow the contract's text: the items as `GET
/api/v1/inbox` lists them; `ahead` as `{"next", "prev", "basedOn"}`; a cursor
answer as `{"item", "visitedDepth", "cursorVersion", "ahead"}`; stream frames
with `id` `<epoch>:<seq>` and a `changed` frame's `entered`, `left`,
`reasons` and `cursors`. Two parts are guesses the contract does not spell
out, and the cases that read them say so in their names: the `cursor` block
of a read with `?cursor=` (`name`, `itemId`, `visitedDepth`,
`cursorVersion`), and an `ahead` on each entry of a frame's `cursors`. They
are replaced by captures when a server serves them.
