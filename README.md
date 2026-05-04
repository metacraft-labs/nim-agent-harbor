# nim-agent-harbor

`nim-agent-harbor` is a transport-neutral Nim client model for Agent Harbor REST and SSE APIs.

Implemented surface:
- `POST /api/v1/tasks`
- `POST /api/v1/sessions/{id}/prompt`
- auth header helpers for API keys and bearer tokens
- SSE `data:` parsing into typed events
- deterministic fake transport tests
