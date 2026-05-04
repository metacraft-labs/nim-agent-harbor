# nim-agent-harbor

Agent Harbor REST/SSE request, response, auth, and stream handling for Nim.

Commands:
- `just build`: compile native and JS targets.
- `just test`: run native and JS tests.
- `just lint`: run Nim and Nix checks.
- `just format`: format Nim and Nix sources.

Structure:
- `src/nim_agent_harbor/types.nim`: REST and event data model.
- `src/nim_agent_harbor/client.nim`: typed client over pluggable HTTP transport.
- `src/nim_agent_harbor/fake.nim`: deterministic fake transport.

Do not import IsoNim Editor or CodeTracer modules here.
