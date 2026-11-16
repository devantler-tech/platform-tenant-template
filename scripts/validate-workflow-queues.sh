#!/usr/bin/env bash
set -euo pipefail
# Complete the concurrency.queue validation missing from actionlint 1.7.12.
# The following lint step retains every other actionlint diagnostic unchanged.
fail() { printf 'workflow queues: %s\n' "$*" >&2; exit 1; }
[[ "$#" -le 1 ]] || fail 'invalid arguments: expected at most one repository root'
root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
command -v yq >/dev/null 2>&1 || fail 'missing yq v4'
command -v jq >/dev/null 2>&1 || fail 'missing jq'
case "$(yq --version)" in *'version v4.'*) ;; *) fail 'missing yq v4';; esac
workflow_dir="$root/.github/workflows"
[[ -d "$workflow_dir" && ! -L "$workflow_dir" ]] || fail 'missing regular workflow directory'
shopt -s nullglob
files=("$workflow_dir"/*.yaml "$workflow_dir"/*.yml)
[[ "${#files[@]}" -gt 0 ]] || fail 'missing workflow files'
for file in "${files[@]}"; do
  [[ -f "$file" && ! -L "$file" ]] || fail "unreadable regular workflow: $file"
  if ! documents="$(yq -o=json '.' "$file")"; then
    fail "unreadable YAML: $file"
  fi
  if ! jq -e -s 'length == 1 and (.[0] | type) == "object"' <<<"$documents" >/dev/null; then
    fail "invalid single workflow document: $file"
  fi
  if ! invalid="$(jq -r -s '
    .[0] |
    [{name: "workflow", value: .concurrency}] +
      [(if (.jobs | type) == "object" then .jobs else {} end | to_entries[])
        | select((.value | type) == "object")
        | {name: .key, value: .value.concurrency}] |
    .[] | . as $scope | .value as $c |
    select(($c | type) == "object") | select($c | has("queue")) |
    if (($c.queue == "single" or $c.queue == "max")
      and (($c.group | type) == "string" and ($c.group | length) > 0)
      and ($c.queue != "max" or
        (($c | has("cancel-in-progress") | not) or $c["cancel-in-progress"] == false)))
    then empty
    else "\($scope.name): expected queue single/max, a group, and non-cancelling max publication"
    end
  ' <<<"$documents")"; then
    fail "unreadable queue declarations: $file"
  fi
  [[ -z "$invalid" ]] || fail "invalid concurrency queue in $file: $invalid"
done
printf 'workflow queues: validated %s workflow files\n' "${#files[@]}"
