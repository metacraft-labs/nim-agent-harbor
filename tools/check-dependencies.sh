#!/usr/bin/env bash
set -euo pipefail

module_name="nim_""acp"
path_name="../nim-""acp/src"

if grep -R --include='*.nim' -nE "(^|[^[:alnum:]_])import[[:space:]].*${module_name}|(^|[^[:alnum:]_])from[[:space:]]+${module_name}|(^|[^[:alnum:]_])include[[:space:]]+${module_name}" src tests; then
  echo "nim_agent_harbor_dependency_check_failed: forbidden ACP import" >&2
  exit 1
fi

if grep -nF -- "$path_name" Justfile; then
  echo "nim_agent_harbor_dependency_check_failed: forbidden ACP path" >&2
  exit 1
fi

echo "nim_agent_harbor_dependency_check_ok"
