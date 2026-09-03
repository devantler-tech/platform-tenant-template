#!/usr/bin/env sh

set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
cd_workflow=$repo_root/.github/workflows/cd.yaml
release_workflow=$repo_root/.github/workflows/release.yaml
template_sync_workflow=$repo_root/.github/workflows/template-sync.yaml

# The commit a devantler-tech/actions release tag points at, read from the forge. An annotated
# tag lists a peeled `^{}` entry as well; that is the commit and wins over the tag object. A tag
# that does not exist prints nothing and succeeds, while a failed read (network, proxy, auth)
# fails and leaves its stderr in $actions_tag_error, so the caller can say which of the two it was.
actions_tag_error=
actions_tag_commit() {
	if ! actions_tag_listing=$(
		GIT_TERMINAL_PROMPT=0 git ls-remote --tags https://github.com/devantler-tech/actions \
			"refs/tags/$1" "refs/tags/$1^{}" 2>&1
	); then
		actions_tag_error=$actions_tag_listing
		return 1
	fi
	printf '%s\n' "$actions_tag_listing" |
		awk 'NF == 2 { if ($2 ~ /\^\{\}$/) peeled = $1; else plain = $1 }
			END { if (peeled != "") print peeled; else if (plain != "") print plain }' |
		grep -Ex '[0-9a-f]{40}'
}
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
	printf '%s\n' "$cd_version" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ||
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

	# BIND THE VERSION COMMENT TO THE COMMIT. Everything above reads the comment, which is the one
	# part of a pin no tooling validates: three callers pinned to v13.1.1's commit while annotated
	# `# v13.1.3` pass every check so far and sit two patch releases below the floor with a green
	# contract. The floor is only a control if the version it gates on is the version actually
	# pinned, so the tag the comment names must resolve to the pinned commit. A tag that cannot be
	# resolved — network down, or a version that was never released — fails closed rather than
	# passing on an unverifiable claim.
	tag_ref=$(actions_tag_commit "$cd_version") ||
		fail "could not resolve refs/tags/$cd_version on devantler-tech/actions, so the version comment cannot be verified against the pinned commit: ${actions_tag_error:-the tag does not exist (no such release)}"
	[ "$tag_ref" = "$cd_ref" ] ||
		fail "devantler-tech/actions callers pin $cd_ref but their version comment names $cd_version, which is $tag_ref; the comment must name the tag of the pinned commit"
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
	'cd.yaml|.jobs.publish.uses' \
	'release.yaml|.jobs.release.uses' \
	'template-sync.yaml|.jobs."template-sync".uses'; do
	file=${pair%%|*}
	path=${pair#*|}
	yq eval "${path} line_comment = \"v13.01.2\"" \
		"$mutation_dir/$file" >"$mutation_dir/mutant.yaml"
	mv "$mutation_dir/mutant.yaml" "$mutation_dir/$file"
done
mutations_run=$((mutations_run + 1))
if (validate_pins "$mutation_dir/cd.yaml" "$mutation_dir/release.yaml" \
	"$mutation_dir/template-sync.yaml") >/dev/null 2>&1; then
	fail 'mutation passed: shared version comment used a leading-zero component'
fi

# Every caller re-pinned to one commit under one comment, so the shared-commit and shared-comment
# checks are satisfied and only the floor or the comment-to-commit binding can reject it.
assert_repin_rejected() {
	description=$1
	repin_sha=$2
	repin_comment=$3
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
			"${path} = \"devantler-tech/actions/.github/workflows/${workflow}.yaml@${repin_sha}\" |
			 ${path} line_comment = \"${repin_comment}\"" \
			"$mutation_dir/$file" >"$mutation_dir/mutant.yaml"
		mv "$mutation_dir/mutant.yaml" "$mutation_dir/$file"
	done
	mutations_run=$((mutations_run + 1))
	if (validate_pins "$mutation_dir/cd.yaml" "$mutation_dir/release.yaml" \
		"$mutation_dir/template-sync.yaml") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

assert_repin_rejected 'every caller rolled back below the reviewed floor' \
	b089a1b041cb86af22cdc57de58a4d7d258dcc32 v13.1.1

current_ref=$(yq eval -r '.jobs.publish.uses | sub(".*@"; "")' "$cd_workflow")
# The issue's own reproduction: v13.1.1's commit wearing a `# v13.1.3` annotation clears the floor
# on the comment alone. Two patch releases below the reviewed floor, and every earlier check green.
assert_repin_rejected 'a below-floor commit annotated with an above-floor version' \
	b089a1b041cb86af22cdc57de58a4d7d258dcc32 v13.1.3
# The honest-mismatch direction: the right commit under a stale comment is still a pin whose
# version claim is false, and a partially applied bump produces exactly this. The stale version
# is ABOVE the floor on purpose — below it, the floor check would reject the mutant first and this
# case would prove nothing about the binding.
assert_repin_rejected 'the current commit annotated with a stale above-floor version' \
	"$current_ref" v13.1.3
# A version that was never released resolves to nothing; an unverifiable claim fails closed. This
# fires on the same branch a network outage would, which is why it runs after the happy path above
# has already proved the forge was reachable in this run.
assert_repin_rejected 'a version comment naming a tag that does not exist' \
	"$current_ref" v99.0.0

printf 'PASS: portable workflow caller pin contract (happy path + %s safety mutations)\n' "$mutations_run"
