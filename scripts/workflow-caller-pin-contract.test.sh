#!/usr/bin/env sh

set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
cd_workflow=$repo_root/.github/workflows/cd.yaml
release_workflow=$repo_root/.github/workflows/release.yaml
template_sync_workflow=$repo_root/.github/workflows/template-sync.yaml

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

validate_pins() {
	cd_file=$1
	release_file=$2
	template_sync_file=$3

	yq eval -e \
		'.jobs.publish.uses | test("^devantler-tech/actions/\\.github/workflows/publish-app\\.yaml@[0-9a-f]{40}$")' \
		"$cd_file" >/dev/null ||
		fail 'the publish caller must pin publish-app.yaml to a commit SHA'
	yq eval -e \
		'.jobs.release.uses | test("^devantler-tech/actions/\\.github/workflows/create-release\\.yaml@[0-9a-f]{40}$")' \
		"$release_file" >/dev/null ||
		fail 'the release caller must pin create-release.yaml to a commit SHA'
	yq eval -e \
		'.jobs."template-sync".uses | test("^devantler-tech/actions/\\.github/workflows/template-sync\\.yaml@[0-9a-f]{40}$")' \
		"$template_sync_file" >/dev/null ||
		fail 'the template-sync caller must pin template-sync.yaml to a commit SHA'

	pinned_ref_of() {
		yq eval -r "$2 | sub(\".*@\"; \"\")" "$1"
	}
	pinned_version_of() {
		yq eval -r "$2 | line_comment" "$1"
	}

	cd_ref=$(pinned_ref_of "$cd_file" '.jobs.publish.uses')
	release_ref=$(pinned_ref_of "$release_file" '.jobs.release.uses')
	template_sync_ref=$(pinned_ref_of "$template_sync_file" '.jobs."template-sync".uses')
	{ [ "$cd_ref" = "$release_ref" ] && [ "$cd_ref" = "$template_sync_ref" ]; } ||
		fail 'every devantler-tech/actions caller must pin the same commit'

	cd_version=$(pinned_version_of "$cd_file" '.jobs.publish.uses')
	release_version=$(pinned_version_of "$release_file" '.jobs.release.uses')
	template_sync_version=$(pinned_version_of "$template_sync_file" '.jobs."template-sync".uses')
	{ [ "$cd_version" = "$release_version" ] && [ "$cd_version" = "$template_sync_version" ]; } ||
		fail 'every devantler-tech/actions caller must carry the same version comment'
	printf '%s\n' "$cd_version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' ||
		fail 'each devantler-tech/actions pin must carry a version comment of the form vX.Y.Z'

	actions_floor_major=13
	actions_floor_minor=1
	actions_floor_patch=2
	pinned_major=$(printf '%s' "${cd_version#v}" | cut -d. -f1)
	pinned_minor=$(printf '%s' "${cd_version#v}" | cut -d. -f2)
	pinned_patch=$(printf '%s' "${cd_version#v}" | cut -d. -f3)
	if [ "$pinned_major" -lt "$actions_floor_major" ] ||
		{ [ "$pinned_major" -eq "$actions_floor_major" ] &&
			[ "$pinned_minor" -lt "$actions_floor_minor" ]; } ||
		{ [ "$pinned_major" -eq "$actions_floor_major" ] &&
			[ "$pinned_minor" -eq "$actions_floor_minor" ] &&
			[ "$pinned_patch" -lt "$actions_floor_patch" ]; }; then
		fail "devantler-tech/actions callers are pinned to $cd_version, older than the reviewed floor v13.1.2"
	fi
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 4 ] ||
		fail 'usage: workflow-caller-pin-contract.test.sh --validate <cd> <release> <template-sync>'
	validate_pins "$2" "$3" "$4"
	exit 0
fi

validate_pins "$cd_workflow" "$release_workflow" "$template_sync_workflow"

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT
mutations_run=0

assert_mutation_rejected() {
	description=$1
	file_kind=$2
	mutation=$3
	mutations_run=$((mutations_run + 1))
	cp "$cd_workflow" "$mutation_dir/cd.yaml"
	cp "$release_workflow" "$mutation_dir/release.yaml"
	cp "$template_sync_workflow" "$mutation_dir/template-sync.yaml"
	yq eval "$mutation" "$mutation_dir/$file_kind.yaml" >"$mutation_dir/mutant.yaml"
	mv "$mutation_dir/mutant.yaml" "$mutation_dir/$file_kind.yaml"
	if (validate_pins "$mutation_dir/cd.yaml" "$mutation_dir/release.yaml" \
		"$mutation_dir/template-sync.yaml") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

assert_mutation_rejected 'publish caller SHA pin removed' cd \
	'.jobs.publish.uses = "devantler-tech/actions/.github/workflows/publish-app.yaml@main"'
assert_mutation_rejected 'release caller SHA pin removed' release \
	'.jobs.release.uses = "devantler-tech/actions/.github/workflows/create-release.yaml@main"'
assert_mutation_rejected 'template-sync caller SHA pin removed' template-sync \
	'.jobs."template-sync".uses = "devantler-tech/actions/.github/workflows/template-sync.yaml@main"'
assert_mutation_rejected 'one caller rolled back below the shared commit' cd \
	'.jobs.publish.uses = "devantler-tech/actions/.github/workflows/publish-app.yaml@b089a1b041cb86af22cdc57de58a4d7d258dcc32"'
assert_mutation_rejected 'one caller version comment diverged' release \
	'.jobs.release.uses line_comment = "v13.1.1"'
assert_mutation_rejected 'version comment became unparseable' template-sync \
	'.jobs."template-sync".uses line_comment = "vLATEST.x.y"'

cp "$cd_workflow" "$mutation_dir/cd.yaml"
cp "$release_workflow" "$mutation_dir/release.yaml"
cp "$template_sync_workflow" "$mutation_dir/template-sync.yaml"
for pair in \
	'cd.yaml|.jobs.publish.uses|publish-app' \
	'release.yaml|.jobs.release.uses|create-release' \
	'template-sync.yaml|.jobs."template-sync".uses|template-sync'; do
	file=${pair%%|*}
	rest=${pair#*|}
	path=${rest%%|*}
	workflow=${rest##*|}
	yq eval \
		"${path} = \"devantler-tech/actions/.github/workflows/${workflow}.yaml@b089a1b041cb86af22cdc57de58a4d7d258dcc32\" |
		 ${path} line_comment = \"v13.1.1\"" \
		"$mutation_dir/$file" >"$mutation_dir/mutant.yaml"
	mv "$mutation_dir/mutant.yaml" "$mutation_dir/$file"
done
mutations_run=$((mutations_run + 1))
if (validate_pins "$mutation_dir/cd.yaml" "$mutation_dir/release.yaml" \
	"$mutation_dir/template-sync.yaml") >/dev/null 2>&1; then
	fail 'mutation passed: every caller rolled back below the reviewed floor'
fi

printf 'PASS: portable workflow caller pin contract (happy path + %s safety mutations)\n' "$mutations_run"
