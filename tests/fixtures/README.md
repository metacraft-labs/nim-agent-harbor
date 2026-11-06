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
