#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/.github/workflows"
fixture="$scratch/.github/workflows/publish.yaml"
fail() { printf 'workflow queue test: %s\n' "$*" >&2; exit 1; }
write_fixture() {
  cat >"$fixture" <<'YAML'
name: Queue fixture
on: workflow_dispatch
jobs:
  publish:
    runs-on: ubuntu-latest
    concurrency:
      group: fixture
      queue: max
      cancel-in-progress: false
    steps:
      - run: echo publish
YAML
}
check() { bash "$root/scripts/validate-workflow-queues.sh" "$scratch"; }
refuse() {
  local reason="$1"
  if check >"$scratch/out" 2>&1; then fail "accepted $reason"; fi
  grep -Eq 'workflow queues: (invalid|unreadable|missing)' "$scratch/out" || fail "wrong refusal for $reason"
}
write_fixture
check
yq -i '.jobs.publish.concurrency.queue = "typo"' "$fixture"
refuse 'an unknown queue policy'
for value in 'null' 'true' '12' '["max"]' '{policy: max}'; do
  write_fixture
  VALUE="$value" yq -i '.jobs.publish.concurrency.queue = (strenv(VALUE) | from_yaml)' "$fixture"
  refuse "a non-string queue: $value"
done
for value in true null "\"\${{ github.ref == 'refs/heads/main' }}\""; do
  write_fixture
  VALUE="$value" yq -i '.jobs.publish.concurrency."cancel-in-progress" = (strenv(VALUE) | from_yaml)' "$fixture"
  refuse "a potentially cancelling max queue: $value"
done
write_fixture
yq -i 'del(.jobs.publish.concurrency.group)' "$fixture"
refuse 'a queue without a group'
write_fixture
yq -i 'del(.jobs.publish.concurrency."cancel-in-progress")' "$fixture"
check
write_fixture
yq -i '.jobs.publish.concurrency.queue = "single" | .jobs.publish.concurrency."cancel-in-progress" = true' "$fixture"
check
write_fixture
yq -i '.concurrency = .jobs.publish.concurrency | del(.jobs.publish.concurrency)' "$fixture"
check
yq -i '.concurrency.queue = "typo"' "$fixture"
refuse 'an invalid workflow-level queue'
write_fixture
yq -i 'del(.jobs.publish.concurrency.queue)' "$fixture"
check
printf 'jobs: [\n' >"$fixture"
refuse 'malformed YAML'
write_fixture
printf '\n---\nname: another\n' >>"$fixture"
refuse 'multiple workflow documents'
rm "$fixture"
refuse 'an empty workflow inventory'
write_fixture
# Exercise the released validator too: the compatibility rule must leave every
# unrelated syntax diagnostic active.
if command -v actionlint >/dev/null 2>&1; then
  actionlint -ignore 'unexpected.key..queue..for..concurrency..section' "$fixture"
  yq -i '.jobs.publish.concurrency.bogus = "typo"' "$fixture"
  check
  if actionlint -ignore 'unexpected.key..queue..for..concurrency..section' "$fixture" >"$scratch/lint" 2>&1; then
    fail 'the compatibility rule hid an unrelated concurrency typo'
  fi
  grep -q 'unexpected key "bogus"' "$scratch/lint" || fail 'the real validator failed for the wrong reason'
else
  fail 'actionlint is required for the independent compatibility control'
fi
printf 'workflow queue tests: passed\n'
