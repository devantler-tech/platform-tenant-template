#!/usr/bin/env sh

set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
release_workflow=$repo_root/.github/workflows/release.yaml
template_sync_workflow=$repo_root/.github/workflows/template-sync.yaml
validation_workflow=$repo_root/.github/workflows/validate-scaffold.yaml

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

yq eval -e \
	'.jobs.release.with."disable-issue-side-effects" == true' \
	"$release_workflow" >/dev/null ||
	fail 'tenant releases must disable semantic-release issue and pull-request side effects'

yq eval -e \
	'.jobs."template-sync".with."use-app-token" == true' \
	"$template_sync_workflow" >/dev/null ||
	fail 'template sync must use the App token so workflow-file updates trigger tenant CI'

yq eval -e '
	[
		.jobs."validate-scaffold".steps[]
		| select(
			(.run // "") == "sh scripts/workflow-caller-contract.test.sh"
			and ((has("if") or has("continue-on-error")) | not)
		)
	] | length == 1
' "$validation_workflow" >/dev/null ||
	fail 'the workflow-caller contract must run unconditionally in required scaffold validation'

printf 'PASS: tenant workflow callers preserve release isolation and App-authenticated sync\n'
