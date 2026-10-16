#!/usr/bin/env bash
# Entering this repository's dev shell from ANOTHER git repository writes
# nothing into that repository.
#
# The dev shell's hook installs git hooks (`.pre-commit-config.yaml`, hooks
# under `.git/hooks`, `core.hooksPath`). git-hooks.nix aims them at
# `git rev-parse --show-toplevel` of the CURRENT DIRECTORY, so without a guard
# `nix develop /path/to/this-repo` run from a sibling checkout plants this
# repository's hooks there: an untracked file that blocks that repository's
# pre-push gate, and foreign checks on its commits. flake.nix runs the hook only
# when the enclosing repository is this one.
#
# Asserted, from a scratch git repository and from a subdirectory of it: no
# file or directory appears, no hook is
# installed and `core.hooksPath` is untouched. As the positive control, entered
# from inside this repository the hook still installs the pre-commit hook
# (running the complete native configuration while leaving the committed
# portable `.pre-commit-config.yaml` byte-identical).
#
#   bash tests/test_dev_shell_writes_nothing_elsewhere.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

git -C "$SCRATCH" init -q
git -C "$SCRATCH" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$SCRATCH/sub"
hooks_before="$(ls "$SCRATCH/.git/hooks")"

for dir in "$SCRATCH" "$SCRATCH/sub"; do
  ( direnv exec "$REPO" bash -c '
      cd "$1"
      test "${NIX_DIRENV_DID_FALLBACK:-0}" != 1
      exec "${NIM_AGENT_HARBOR_HOOK_INSTALLER:?owning shell required}"
    ' bash "$dir" ) >/dev/null 2>&1 \
    || fail "the dev shell did not start from $dir"
  [ -z "$(git -C "$SCRATCH" status --porcelain --ignored)" ] \
    || fail "entered from $dir: files were written into the other repository: $(git -C "$SCRATCH" status --porcelain --ignored | tr '\n' ' ')"
  # git status does not list empty directories.
  extra="$(cd "$SCRATCH" && find . -mindepth 1 -path ./.git -prune -o ! -path ./sub -print)"
  [ -z "$extra" ] || fail "entered from $dir: entries were created in the other repository: $(echo $extra)"
  [ "$(ls "$SCRATCH/.git/hooks")" = "$hooks_before" ] \
    || fail "entered from $dir: git hooks were installed into the other repository"
  [ -z "$(git -C "$SCRATCH" config --local --get core.hooksPath || true)" ] \
    || fail "entered from $dir: the other repository's core.hooksPath was changed"
done

# Positive control: the guard must not stop the hook in this repository.
config_before="$(git -C "$REPO" hash-object .pre-commit-config.yaml)"
hooks_dir="$(git -C "$REPO" rev-parse --path-format=absolute --git-path hooks)"
( direnv exec "$REPO" bash -c '
    cd "$1"
    test "${NIX_DIRENV_DID_FALLBACK:-0}" != 1
    exec "${NIM_AGENT_HARBOR_HOOK_INSTALLER:?owning shell required}"
  ' bash "$REPO" ) >/dev/null 2>&1 \
  || fail "the dev shell did not start from this repository"
[ -f "$REPO/.pre-commit-config.yaml" ] && [ ! -L "$REPO/.pre-commit-config.yaml" ] \
  && [ "$(git -C "$REPO" hash-object .pre-commit-config.yaml)" = "$config_before" ] \
  || fail "control: the committed .pre-commit-config.yaml was replaced or changed"
[ -L "$REPO/.pre-commit-config.nix.yaml" ] \
  || fail "control: complete native config was not installed"
# The owning environment supplies these immutable constructor authorities.
expected_native="${NIM_AGENT_HARBOR_EXPECTED_NATIVE_HOOKS:?owning shell required}"
expected_config="${NIM_AGENT_HARBOR_FULL_HOOK_CONFIG:?owning shell required}"
[ "$(readlink "$REPO/.pre-commit-config.nix.yaml")" = "$expected_config" ] \
  || fail "control: the native configuration differs from its declared source"
cmp "$hooks_dir/pre-commit.repro-local" "$expected_native/pre-commit" \
  || fail "control: the complete native hook body differs from its declared factory"

echo "PASS: entered from another repository the dev shell writes nothing there; from this one it installs its hooks"
