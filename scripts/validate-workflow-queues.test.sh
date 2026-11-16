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
# Exercise the scaffold matrix's committed compatibility arguments, not a copy
# of them: that entry point must validate queues before its linter ignores the
# unsupported field, and retain unrelated syntax diagnostics.
write_fixture
scaffold_workflow="$root/.github/workflows/validate-stacks.yaml"
scaffold_arguments=$(yq -r '.jobs.stack.steps[] | select(.uses // "" | contains("oxsecurity/megalinter/")) | .env.ACTION_ACTIONLINT_ARGUMENTS' "$scaffold_workflow")
read -r -a scaffold_lint_arguments <<<"$scaffold_arguments"
actionlint "${scaffold_lint_arguments[@]}" "$fixture"
yq -o=json '.jobs.stack.steps' "$scaffold_workflow" | jq -e '
  to_entries as $steps |
  [$steps[] | select(.value.run // "" | contains("validate-workflow-queues.sh"))] as $guards |
  [$steps[] | select(.value.uses // "" | contains("oxsecurity/megalinter/"))] as $linters |
  ($guards | length) == 1 and ($linters | length) == 1 and
  $guards[0].key < $linters[0].key and
  $guards[0].value.if == $linters[0].value.if and
  $guards[0].value."working-directory" == "${{ env.APP }}"
' >/dev/null || fail 'the scaffold compatibility rule lacks its preceding queue gate'
yq -r '.jobs.stack.steps[] | select(.run // "" | contains("validate-workflow-queues.sh")) | .run' "$scaffold_workflow" >"$scratch/scaffold-guard.sh"
mkdir -p "$scratch/scripts"
cp "$root/scripts/validate-workflow-queues.sh" "$scratch/scripts/"
scaffold_check() { (cd "$scratch" && bash -e -o pipefail "$scratch/scaffold-guard.sh"); }
scaffold_check
yq -i '.jobs.publish.concurrency.queue = "typo"' "$fixture"
if scaffold_check >"$scratch/out" 2>&1; then fail 'the scaffold queue gate accepted an invalid policy'; fi
grep -q 'workflow queues: invalid' "$scratch/out" || fail 'the scaffold gate failed for the wrong reason'
write_fixture
yq -i '.jobs.publish.concurrency.bogus = "typo"' "$fixture"
scaffold_check
if actionlint "${scaffold_lint_arguments[@]}" "$fixture" >"$scratch/lint" 2>&1; then
  fail 'the scaffold compatibility arguments hid an unrelated concurrency typo'
fi
grep -q 'unexpected key "bogus"' "$scratch/lint" || fail 'the scaffold linter failed for the wrong reason'
# A failed-jobs rerun retains successful slots from earlier attempts. Exercise
# the real receipt step with that API shape, including an older failed slot.
mkdir "$scratch/bin"
cat >"$scratch/bin/gh" <<'SH'
#!/usr/bin/env bash
case "${*: -1}" in
  */jobs\?filter=all\&per_page=100) cat "$QUEUE_FIXTURES/jobs.json" ;;
  */artifacts\?per_page=100) cat "$QUEUE_FIXTURES/artifacts.json" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$scratch/bin/gh"
yq -r '.jobs."release-queue-receipts".steps[0].run' "$root/.github/workflows/ci.yaml" >"$scratch/receipts.sh"
jq -n '[{jobs: [
  {id:1,name:"Release queue proof (first)",run_attempt:1,status:"completed",conclusion:"success"},
  {id:2,name:"Release queue proof (second)",run_attempt:1,status:"completed",conclusion:"failure"},
  {id:3,name:"Release queue proof (third)",run_attempt:1,status:"completed",conclusion:"success"},
  {id:4,name:"Release queue proof (second)",run_attempt:2,status:"completed",conclusion:"success"}
]}]' >"$scratch/jobs.json"
jq -n '[{artifacts:["first","second","third"] | map({name:("release-queue-proof-" + .),expired:false,size_in_bytes:100})}]' >"$scratch/artifacts.json"
receipt_check() {
  PATH="$scratch/bin:$PATH" QUEUE_FIXTURES="$scratch" GITHUB_REPOSITORY=fixture/repo \
    GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=2 bash -e -o pipefail "$scratch/receipts.sh"
}
receipt_check >/dev/null
jq '.[0].jobs[-1].conclusion = "failure"' "$scratch/jobs.json" >"$scratch/changed.json"
mv "$scratch/changed.json" "$scratch/jobs.json"
if receipt_check >/dev/null 2>&1; then fail 'a failed latest slot reused an earlier result'; fi
printf 'workflow queue tests: passed\n'
