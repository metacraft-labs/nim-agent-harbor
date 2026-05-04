alias t := test
alias fmt := format

paths := "--path:src --path:../nim-everywhere/src"

build: check-dependencies build-native build-js

build-native:
    nim c {{paths}} tests/test_agent_harbor.nim

build-js:
    nim js {{paths}} tests/test_agent_harbor.nim

test: check-dependencies test-native test-js

test-native:
    nim c -r {{paths}} tests/test_agent_harbor.nim

test-js:
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_agent_harbor.nim

lint: check-dependencies lint-nim lint-nix

check-dependencies:
    bash tools/check-dependencies.sh

lint-nim:
    nim check {{paths}} tests/test_agent_harbor.nim

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
