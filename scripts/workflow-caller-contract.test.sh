#!/usr/bin/env sh

set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
cd_workflow=$repo_root/.github/workflows/cd.yaml
release_workflow=$repo_root/.github/workflows/release.yaml
template_sync_workflow=$repo_root/.github/workflows/template-sync.yaml
validation_workflow=$repo_root/.github/workflows/validate-scaffold.yaml
readme=$repo_root/README.md
template_sync_ignore=$repo_root/.templatesyncignore

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

validate_contract() {
	cd_file=$1
	release_file=$2
	template_sync_file=$3
	validation_file=$4
	readme_file=$5
	ignore_file=$6

	yq eval -e \
		'.jobs.publish.uses | test("^devantler-tech/actions/\\.github/workflows/publish-app\\.yaml@[0-9a-f]{40}$")' \
		"$cd_file" >/dev/null ||
		fail 'the publish caller must pin publish-app.yaml to a commit SHA'

	yq eval -e '.jobs.publish.with."enable-caller-pin" == true' \
		"$cd_file" >/dev/null ||
		fail 'the publish caller must keep the producer-side ref guard enabled'

	yq eval -e \
		'.jobs.release.uses | test("^devantler-tech/actions/\\.github/workflows/create-release\\.yaml@[0-9a-f]{40}$")' \
		"$release_file" >/dev/null ||
		fail 'the release caller must pin create-release.yaml to a commit SHA'

	yq eval -e \
		'.jobs."template-sync".uses | test("^devantler-tech/actions/\\.github/workflows/template-sync\\.yaml@[0-9a-f]{40}$")' \
		"$template_sync_file" >/dev/null ||
		fail 'the template-sync caller must pin template-sync.yaml to a commit SHA'

	yq eval -e \
		'.jobs.release.with."disable-issue-side-effects" == true' \
		"$release_file" >/dev/null ||
		fail 'tenant releases must disable semantic-release issue and pull-request side effects'

	yq eval -e \
		'.jobs."template-sync".with."use-app-token" == true' \
		"$template_sync_file" >/dev/null ||
		fail 'template sync must use the App token so workflow-file updates trigger tenant CI'

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
	' "$readme_file")
	printf '%s\n' "$owned_ignore_block" |
		grep -Fxq -- 'scripts/workflow-caller-contract.test.sh' ||
		fail 'README ignore example lacks the workflow-caller contract'
	grep -Fxq -- 'scripts/workflow-caller-contract.test.sh' "$ignore_file" ||
		fail '.templatesyncignore lacks the workflow-caller contract'
	grep -Fq "\`scripts/workflow-caller-contract.test.sh\`" "$readme_file" ||
		fail 'README ownership table lacks the workflow-caller contract'
	grep -Fq 'sh scripts/workflow-caller-contract.test.sh' "$readme_file" ||
		fail 'README local validation lacks the workflow-caller contract'
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 7 ] ||
		fail 'usage: workflow-caller-contract.test.sh --validate <cd> <release> <template-sync> <validation> <readme> <ignore>'
	validate_contract "$2" "$3" "$4" "$5" "$6" "$7"
	exit 0
fi

validate_contract \
	"$cd_workflow" \
	"$release_workflow" \
	"$template_sync_workflow" \
	"$validation_workflow" \
	"$readme" \
	"$template_sync_ignore"

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT
mutations_run=0

run_mutation() {
	description=$1
	file_kind=$2
	mutation=$3
	mutations_run=$((mutations_run + 1))

	cp "$cd_workflow" "$mutation_dir/cd.yaml"
	cp "$release_workflow" "$mutation_dir/release.yaml"
	cp "$template_sync_workflow" "$mutation_dir/template-sync.yaml"
	cp "$validation_workflow" "$mutation_dir/validation.yaml"
	cp "$readme" "$mutation_dir/README.md"
	cp "$template_sync_ignore" "$mutation_dir/templatesyncignore"

	case "$file_kind" in
	cd | release | template-sync | validation)
		yq eval "$mutation" "$mutation_dir/$file_kind.yaml" > "$mutation_dir/mutant.yaml"
		mv "$mutation_dir/mutant.yaml" "$mutation_dir/$file_kind.yaml"
		;;
	readme)
		sed "$mutation" "$mutation_dir/README.md" > "$mutation_dir/mutant.md"
		mv "$mutation_dir/mutant.md" "$mutation_dir/README.md"
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
		"$mutation_dir/README.md" \
		"$mutation_dir/templatesyncignore") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_mutation 'publish caller SHA pin removed' cd \
	'.jobs.publish.uses = "devantler-tech/actions/.github/workflows/publish-app.yaml@main"'
run_mutation 'publisher-side caller pin disabled' cd \
	'.jobs.publish.with."enable-caller-pin" = false'
run_mutation 'release caller SHA pin removed' release \
	'.jobs.release.uses = "devantler-tech/actions/.github/workflows/create-release.yaml@main"'
run_mutation 'release issue isolation disabled' release \
	'.jobs.release.with."disable-issue-side-effects" = false'
run_mutation 'template-sync caller SHA pin removed' template-sync \
	'.jobs."template-sync".uses = "devantler-tech/actions/.github/workflows/template-sync.yaml@main"'
run_mutation 'template-sync App token disabled' template-sync \
	'.jobs."template-sync".with."use-app-token" = false'
run_mutation 'required scaffold invocation removed' validation \
	'del(.jobs."validate-scaffold".steps[] | select(.run == "sh scripts/workflow-caller-contract.test.sh"))'
run_mutation 'README ownership table marker removed' readme \
	"/\`scripts\/workflow-caller-contract\.test\.sh\`/d"
run_mutation 'README ignore marker removed' readme \
	'/^scripts\/workflow-caller-contract\.test\.sh$/d'
run_mutation 'README local validation marker removed' readme \
	'/sh scripts\/workflow-caller-contract\.test\.sh/d'
run_mutation 'actual ownership marker removed' ignore \
	'/^scripts\/workflow-caller-contract\.test\.sh$/d'

printf 'PASS: tenant workflow caller contract (happy path + %s safety mutations)\n' "$mutations_run"
