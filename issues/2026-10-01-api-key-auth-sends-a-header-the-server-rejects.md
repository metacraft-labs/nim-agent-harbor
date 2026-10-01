# API-key authentication sends `X-API-Key`, which the Agent Harbor REST server does not accept

| | |
|---|---|
| Status | open |
| Recorded | 2026-10-01 |
| Observed in | nim-agent-harbor @ c1616880 (`src/nim_agent_harbor/client.nim`, `authHeaders`) |
| Area | REST client authentication |
| Found by | Self-Healing Pipeline campaign review (`codetracer-specs/Observability-Platform/docs/self-healing-campaign-review.md`) |

## Observed

`authHeaders` maps the two auth kinds to these headers:

```nim
of akApiKey: @[header("X-API-Key", auth.token)]
of akBearer: @[header("Authorization", "Bearer " & auth.token)]
```

The Agent Harbor REST server reads only the `Authorization` header, in
`auth_middleware` in `agent-harbor/crates/ah-rest-server/src/auth.rs` at
agent-harbor `601bb9a8`:

```rust
Some(auth) if auth.starts_with("ApiKey ") => { ... validate_api_key ... }
Some(auth) if auth.starts_with("Bearer ") => { ... validate_jwt ... }
_ => if auth_config.requires_auth() { Err("Missing or invalid authorization header") } ...
```

So with authentication enabled, every request made with `akApiKey` is
rejected. With authentication disabled, any header passes. That is why the
library's tests, which use the canned transport in
`src/nim_agent_harbor/fake.nim`, never noticed.

This is inferred from the code of both sides; no request against a running
server was made. The `x-api-key` occurrences elsewhere in agent-harbor
(`crates/ah-agents`, `crates/ah-cli/src/agent/start.rs`) are outbound
headers to model providers, not something the REST server accepts.

## Expected

The Agent Harbor REST specification describes API-key authentication as
`Authorization: ApiKey <key>` (`agent-harbor/specs/Public/REST-Service/API.md`,
authentication section). The server implements exactly that. The client
should send the same thing.

## Evidence

```sh
grep -n 'X-API-Key' nim-agent-harbor/src/nim_agent_harbor/client.nim
grep -rni 'x-api-key' agent-harbor/crates/ah-rest-server   # no matches
```

These were run against nim-agent-harbor `dev` at `c1616880` and agent-harbor
`agents` at `601bb9a8`.

## Suggested direction

Send `Authorization: ApiKey <key>` for `akApiKey`. Add a test that starts a
real `ah-rest-server` with authentication enabled, so the transport is not
faked on the path the test is meant to prove. The test should assert 201 for
the correct header and 401 for `X-API-Key`.

This is the repository's first issue, so the archive search found nothing.

## Related

- `codetracer-specs/Observability-Platform/Self-Healing-Pipeline.milestones.org` HS-M6, which depends on this fix.
