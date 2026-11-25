# nim-agent-harbor

Agent Harbor REST/SSE request, response, auth, and stream handling for Nim.

Commands:
- `just build`: compile native and JS targets.
- `just test`: run native and JS tests.
- `just lint`: run Nim and Nix checks.
- `just format`: format Nim and Nix sources.

Structure:
- `src/nim_agent_harbor/types.nim`: REST and event data model. A wire number read into an `int` goes through its private `wireInt`, held to the 32-bit range `int` has under JS, never through std/json's `getInt` or `.int`, which raise a RangeDefect there on a wider value; a check that compares wire values (the context-limit quota) compares the `getBiggestInt` values, not the clamped ones.
- `src/nim_agent_harbor/client.nim`: typed client over pluggable HTTP transport.
- `src/nim_agent_harbor/fake.nim`: deterministic fake transport.

Do not import IsoNim Editor or CodeTracer modules here.
