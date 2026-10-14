alias t := test
alias fmt := format

paths := "--path:src --path:../nim-everywhere/src"

build: check-dependencies build-native build-js

build-native:
    nim c --threads:on -d:futureLogging {{paths}} tests/test_native_stream_lifecycle.nim
    nim c {{paths}} tests/test_agent_harbor.nim
    nim c {{paths}} tests/test_real_server_auth.nim
    nim c --threads:on {{paths}} tests/test_native_deadlines.nim
    nim c {{paths}} tests/test_nimcache_is_worktree_local.nim

build-js:
    nim js {{paths}} tests/test_agent_harbor.nim

test: check-dependencies test-native test-js

test-native:
    nim c -r --threads:on -d:futureLogging {{paths}} tests/test_native_stream_lifecycle.nim
    nim c -r {{paths}} tests/test_agent_harbor.nim
    nim c -r {{paths}} tests/test_real_server_auth.nim
    nim c -r --threads:on {{paths}} tests/test_native_deadlines.nim
    nim c -r {{paths}} tests/test_nimcache_is_worktree_local.nim

test-js:
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_agent_harbor.nim

lint: check-dependencies lint-nim lint-nix

check-dependencies:
    bash tools/check-dependencies.sh

lint-nim:
    nim check --threads:on -d:futureLogging {{paths}} tests/test_native_stream_lifecycle.nim
    nim check {{paths}} tests/test_agent_harbor.nim
    nim check {{paths}} tests/test_real_server_auth.nim
    nim check --threads:on {{paths}} tests/test_native_deadlines.nim
    nim check {{paths}} tests/test_nimcache_is_worktree_local.nim

lint-nix:
    nixfmt --check flake.nix

format: format-nim format-nix

format-nim:
    nimpretty src/nim_agent_harbor.nim src/nim_agent_harbor/*.nim tests/*.nim

format-nix:
    nixfmt flake.nix

bump-version version:
    sed -i "s/^version       = .*/version       = \"{{version}}\"/" nim_agent_harbor.nimble
    printf "%s\n" "{{version}}" > VERSION

# Entering the dev shell from another git repository must write nothing there.
# Runs `nix develop`, so it is not part of the in-shell test recipes.
test-dev-shell:
    bash tests/test_dev_shell_writes_nothing_elsewhere.sh
