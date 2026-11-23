#!/usr/bin/env sh

set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
cd_workflow=$repo_root/.github/workflows/cd.yaml
release_workflow=$repo_root/.github/workflows/release.yaml
template_sync_workflow=$repo_root/.github/workflows/template-sync.yaml
validation_workflow=$repo_root/.github/workflows/validate-scaffold.yaml
reference=$repo_root/docs/REFERENCE.md
template_sync_ignore=$repo_root/.templatesyncignore

# Report an unsafe scaffold caller configuration and stop the contract run.
fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

mutation_dir=
trap 'rm -rf ${mutation_dir:+"$mutation_dir"}' EXIT

# Validate the shipped callers and this contract's own ownership markers.
validate_contract() {
	cd_file=$1
	release_file=$2
	template_sync_file=$3
	validation_file=$4
	reference_file=$5
	ignore_file=$6

	# The starter signs as this repository: a direct publish-app action, never the
	# retired shared reusable publisher. The release-tag signing frame it relies on is
	# checked by scripts/platform-tenant-envelope.test.sh against Platform's verifier.
	yq eval -e '(.jobs.publish | has("uses") | not)
		and ([.jobs.publish.steps[] | select(.id == "publish")] | length == 1)
		and ((.jobs.publish.steps[] | select(.id == "publish")).uses | test("^devantler-tech/[.]github/actions/publish-app@[0-9a-f]{40}$"))' \
		"$cd_file" >/dev/null ||
		fail 'the starter must sign its own releases with the publish-app action'

	yq eval -e \
		'.jobs.release.with."disable-issue-side-effects" == true' \
		"$release_file" >/dev/null ||
		fail 'tenant releases must disable semantic-release issue and pull-request side effects'

	yq eval -e \
		'.jobs."template-sync".with."use-app-token" == true' \
		"$template_sync_file" >/dev/null ||
		fail 'template sync must use the App token so workflow-file updates trigger tenant CI'

	yq eval -e \
		'.jobs."template-sync".with."merge-template-ignore-entries" == true' \
		"$template_sync_file" >/dev/null ||
		fail 'template sync must merge the template ignore entries so an exclusion added here reaches tenants created before it'

	yq eval -e '
		[
			.jobs."validate-scaffold".steps[]
			| select(
				(.run // "") == "sh scripts/workflow-caller-contract.test.sh"
				and ((has("if") or has("continue-on-error")) | not)
			)
		] | length == 1
	' "$validation_file" >/dev/null ||
		fail 'the workflow-caller contract must run unconditionally in required scaffold validation'

	owned_ignore_block=$(awk '
		/^\*\*Yours \(list these in `\.templatesyncignore`\):\*\*$/ { found = 1; next }
		found && /^```gitignore$/ { inside = 1; next }
		inside && /^```$/ { exit }
		inside { print }
	' "$reference_file")
	printf '%s\n' "$owned_ignore_block" |
		grep -Fxq -- 'scripts/workflow-caller-contract.test.sh' ||
		fail 'reference ignore example lacks the workflow-caller contract'
	grep -Fxq -- 'scripts/workflow-caller-contract.test.sh' "$ignore_file" ||
		fail '.templatesyncignore lacks the workflow-caller contract'
	grep -Fq "\`scripts/workflow-caller-contract.test.sh\`" "$reference_file" ||
		fail 'reference ownership table lacks the workflow-caller contract'
	grep -Fq 'sh scripts/workflow-caller-contract.test.sh' "$reference_file" ||
		fail 'reference local validation lacks the workflow-caller contract'
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 7 ] ||
		fail 'usage: workflow-caller-contract.test.sh --validate <cd> <release> <template-sync> <validation> <reference> <ignore>'
	validate_contract "$2" "$3" "$4" "$5" "$6" "$7"
	exit 0
fi

validate_contract \
	"$cd_workflow" \
	"$release_workflow" \
	"$template_sync_workflow" \
	"$validation_workflow" \
	"$reference" \
	"$template_sync_ignore"

mutation_dir=$(mktemp -d)
mutations_run=0

# Require the modified scaffold to fail for the named safety condition.
run_mutation() {
	description=$1
	file_kind=$2
	mutation=$3
	mutations_run=$((mutations_run + 1))

	cp "$cd_workflow" "$mutation_dir/cd.yaml"
	cp "$release_workflow" "$mutation_dir/release.yaml"
	cp "$template_sync_workflow" "$mutation_dir/template-sync.yaml"
	cp "$validation_workflow" "$mutation_dir/validation.yaml"
	cp "$reference" "$mutation_dir/REFERENCE.md"
	cp "$template_sync_ignore" "$mutation_dir/templatesyncignore"

	case "$file_kind" in
	cd | release | template-sync | validation)
		yq eval "$mutation" "$mutation_dir/$file_kind.yaml" > "$mutation_dir/mutant.yaml"
		mv "$mutation_dir/mutant.yaml" "$mutation_dir/$file_kind.yaml"
		;;
	reference)
		sed "$mutation" "$mutation_dir/REFERENCE.md" > "$mutation_dir/mutant.md"
		mv "$mutation_dir/mutant.md" "$mutation_dir/REFERENCE.md"
		;;
	ignore)
		sed "$mutation" "$mutation_dir/templatesyncignore" > "$mutation_dir/mutant.ignore"
		mv "$mutation_dir/mutant.ignore" "$mutation_dir/templatesyncignore"
		;;
	*) fail "unknown mutation target: $file_kind" ;;
	esac

	if (validate_contract \
		"$mutation_dir/cd.yaml" \
		"$mutation_dir/release.yaml" \
		"$mutation_dir/template-sync.yaml" \
		"$mutation_dir/validation.yaml" \
		"$mutation_dir/REFERENCE.md" \
		"$mutation_dir/templatesyncignore") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_mutation 'publish caller SHA pin removed' cd \
	'.jobs.publish.steps[2].uses = "devantler-tech/.github/actions/publish-app@main"'
run_mutation 'legacy publisher restored' cd \
	'.jobs.publish = {"name": "Publish", "uses": "devantler-tech/actions/.github/workflows/publish-app.yaml@ea4df9004d4ab43b6c9af5b0c5f55712f7211328", "with": {"app-name": "x"}}'
run_mutation 'shared publisher restored' cd \
	'.jobs.publish = {"name": "Publish", "uses": "devantler-tech/.github/.github/workflows/publish-app.yaml@af042c540ce8db4d64add98c34b5c57691e0e812", "with": {"app-name": "x", "enable-caller-pin": true}}'
run_mutation 'release issue isolation disabled' release \
	'.jobs.release.with."disable-issue-side-effects" = false'
run_mutation 'template-sync App token disabled' template-sync \
	'.jobs."template-sync".with."use-app-token" = false'
run_mutation 'template-sync ignore-entry merge disabled' template-sync \
	'.jobs."template-sync".with."merge-template-ignore-entries" = false'
run_mutation 'template-sync ignore-entry merge removed' template-sync \
	'del(.jobs."template-sync".with."merge-template-ignore-entries")'
run_mutation 'required scaffold invocation removed' validation \
	'del(.jobs."validate-scaffold".steps[] | select(.run == "sh scripts/workflow-caller-contract.test.sh"))'
run_mutation 'reference ownership table marker removed' reference \
	"/\`scripts\/workflow-caller-contract\.test\.sh\`/d"
run_mutation 'reference ignore marker removed' reference \
	'/^scripts\/workflow-caller-contract\.test\.sh$/d'
run_mutation 'reference local validation marker removed' reference \
	'/sh scripts\/workflow-caller-contract\.test\.sh/d'
run_mutation 'actual ownership marker removed' ignore \
	'/^scripts\/workflow-caller-contract\.test\.sh$/d'

printf 'PASS: tenant workflow caller contract (happy path + %s safety mutations)\n' "$mutations_run"
