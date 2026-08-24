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
dependabot_config=$repo_root/.github/dependabot.yml

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
	dependabot_file=$7

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

	# Every caller must ride the SAME devantler-tech/actions commit, and that commit must be
	# labelled no older than the reviewed floor below. Shape alone (the `@[0-9a-f]{40}` tests
	# above) is satisfied by any SHA in either direction, so on its own it cannot tell a forward
	# bump from a rollback — which is how this template came to hold two different versions at
	# once, and how template-sync then proposed moving a tenant backwards.
	#
	# Boundary: this half is deterministic and offline, so it runs in required CI. It compares
	# the callers against each other and against a committed floor; it does NOT ask the network
	# what the newest release is. Detecting that the floor itself has fallen behind upstream is
	# the network-dependent half and belongs on the scheduled run.
	#
	# Residual: the floor is read from each pin's `# vX.Y.Z` line comment, which Dependabot
	# writes alongside the SHA. A comment that overstates its SHA would pass here; the shared-SHA
	# assertion bounds that to a single mislabelled commit applied to all three callers, and only
	# the network-dependent check described above would close it outright.
	actions_floor_major=13
	actions_floor_minor=1
	actions_floor_patch=2

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
		fail 'every devantler-tech/actions caller must pin the same commit, so template-sync cannot carry one workflow forward while rolling another back'

	cd_version=$(pinned_version_of "$cd_file" '.jobs.publish.uses')
	release_version=$(pinned_version_of "$release_file" '.jobs.release.uses')
	template_sync_version=$(pinned_version_of "$template_sync_file" '.jobs."template-sync".uses')

	{ [ "$cd_version" = "$release_version" ] && [ "$cd_version" = "$template_sync_version" ]; } ||
		fail 'every devantler-tech/actions caller must carry the same version comment as its pinned commit'

	# The two assertions above require all three callers to move together. Dependabot treats
	# each reusable workflow as its own dependency, so with no group it opens one pull request
	# per caller — #156, #157 and #158 each touched exactly one file — and every one of them
	# arrives with the other two still behind, failing those assertions in required CI. No merge
	# order rescues it: whichever caller is updated first disagrees with the remaining two. The
	# group is therefore not a configuration preference, it is what makes the shared-commit
	# invariant reachable at all, so it is asserted here rather than left in a comment that a
	# later edit can quietly drop while this test keeps passing.
	#
	# `applies-to` is part of the same condition rather than a second assertion beside it: a
	# group scoped to `security-updates` still leaves routine version bumps arriving one caller
	# at a time, which is the wedge itself, and the default when the key is absent is
	# `version-updates`. Asserting the covering group separately would be subsumed by this one
	# and could never fail on its own.
	#
	# `exclude-patterns` is rejected outright rather than pattern-matched. GitHub applies it AFTER
	# `patterns`, so a group carrying both an inclusion covering these callers and an exclusion
	# removing them satisfies an inclusion-only check while Dependabot still opens one PR per
	# caller — the fail-open this gate exists to close, reintroduced one key lower. Matching
	# exclusion globs instead would mean deciding whether an arbitrary glob subsumes three
	# dependency names, which has no bounded expression here and invites exactly the
	# spelling-by-spelling chase a whitelist ends: this group binds three named dependencies
	# together, so there is no exclusion it could legitimately carry, and any is refused.
	yq eval -e \
		'[.updates[] | select(."package-ecosystem" == "github-actions") | .groups // {} | .[]
		  | select([.patterns // [] | .[]] | contains(["devantler-tech/*"]))
		  | select((."applies-to" // "version-updates") == "version-updates")
		  | select(((."exclude-patterns" // []) | length) == 0)] | length > 0' \
		"$dependabot_file" >/dev/null ||
		fail 'dependabot must carry a github-actions group whose patterns cover devantler-tech/* and which applies to version updates, so all three callers advance in one pull request; without it the shared-commit assertion above blocks every dependency update'

	# Anchored and exactly three components. A looser glob such as `v*.*.*` also matches
	# `v13.1.3.0`, whose fourth component `cut` then silently drops — and a non-numeric
	# component would reach the arithmetic below, where `[ 1a -lt 13 ]` is an *error* rather
	# than a false. An error inside an `if` condition evaluates as false, and `set -eu` does
	# not cover `if` conditions, so anything this gate lets through fails OPEN against the floor.
	printf '%s\n' "$cd_version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' ||
		fail 'each devantler-tech/actions pin must carry a version comment of the form vX.Y.Z naming the release it points at'

	pinned_major=$(printf '%s' "${cd_version#v}" | cut -d. -f1)
	pinned_minor=$(printf '%s' "${cd_version#v}" | cut -d. -f2)
	pinned_patch=$(printf '%s' "${cd_version#v}" | cut -d. -f3)


	# Ordered comparison, not equality: a forward bump of all three callers must stay green with
	# no edit to this test, or the tax of updating it is exactly what produces a stale pin.
	if [ "$pinned_major" -lt "$actions_floor_major" ] ||
		{ [ "$pinned_major" -eq "$actions_floor_major" ] &&
			[ "$pinned_minor" -lt "$actions_floor_minor" ]; } ||
		{ [ "$pinned_major" -eq "$actions_floor_major" ] &&
			[ "$pinned_minor" -eq "$actions_floor_minor" ] &&
			[ "$pinned_patch" -lt "$actions_floor_patch" ]; }; then
		fail "devantler-tech/actions callers are pinned to $cd_version, older than the reviewed floor v$actions_floor_major.$actions_floor_minor.$actions_floor_patch (signed template-sync App commits, and the harden-runner bump publish-app and create-release carry)"
	fi

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
	[ "$#" -eq 8 ] ||
		fail 'usage: workflow-caller-contract.test.sh --validate <cd> <release> <template-sync> <validation> <readme> <ignore> <dependabot>'
	validate_contract "$2" "$3" "$4" "$5" "$6" "$7" "$8"
	exit 0
fi

validate_contract \
	"$cd_workflow" \
	"$release_workflow" \
	"$template_sync_workflow" \
	"$validation_workflow" \
	"$readme" \
	"$template_sync_ignore" \
	"$dependabot_config"

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
	cp "$dependabot_config" "$mutation_dir/dependabot.yml"

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
	dependabot)
		yq eval "$mutation" "$mutation_dir/dependabot.yml" > "$mutation_dir/mutant.yaml"
		mv "$mutation_dir/mutant.yaml" "$mutation_dir/dependabot.yml"
		;;
	*) fail "unknown mutation target: $file_kind" ;;
	esac

	if (validate_contract \
		"$mutation_dir/cd.yaml" \
		"$mutation_dir/release.yaml" \
		"$mutation_dir/template-sync.yaml" \
		"$mutation_dir/validation.yaml" \
		"$mutation_dir/README.md" \
		"$mutation_dir/templatesyncignore" \
		"$mutation_dir/dependabot.yml") >/dev/null 2>&1; then
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
run_mutation 'template-sync verified App commit path regressed' template-sync \
	'.jobs."template-sync".uses = "devantler-tech/actions/.github/workflows/template-sync.yaml@b089a1b041cb86af22cdc57de58a4d7d258dcc32"'
run_mutation 'template-sync unapproved commit substituted' template-sync \
	'.jobs."template-sync".uses = "devantler-tech/actions/.github/workflows/template-sync.yaml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
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
run_mutation 'dependabot group for the devantler-tech callers removed' dependabot \
	'del(.updates[] | select(."package-ecosystem" == "github-actions") | .groups)'
run_mutation 'dependabot group narrowed so it no longer covers the devantler-tech callers' dependabot \
	'(.updates[] | select(."package-ecosystem" == "github-actions") | .groups."devantler-tech-actions".patterns) = ["actions/*"]'
run_mutation 'dependabot group scoped to security updates, leaving version bumps ungrouped' dependabot \
	'(.updates[] | select(."package-ecosystem" == "github-actions") | .groups."devantler-tech-actions"."applies-to") = "security-updates"'
run_mutation 'dependabot group excluding back out the callers it includes' dependabot \
	'(.updates[] | select(."package-ecosystem" == "github-actions") | .groups."devantler-tech-actions"."exclude-patterns") = ["devantler-tech/*"]'
run_mutation 'dependabot group excluding a single caller from the group' dependabot \
	'(.updates[] | select(."package-ecosystem" == "github-actions") | .groups."devantler-tech-actions"."exclude-patterns") = ["devantler-tech/actions/.github/workflows/cd*"]'


# A whole-fleet rollback is the case single-file mutation cannot express: every caller still
# agrees with every other, so only the version floor can reject it. This is the shape #149 saw
# in the wild and the one #152 asks for RED/GREEN proof on.
run_fleet_mutation() {
	description=$1
	ref=$2
	version=$3
	mutations_run=$((mutations_run + 1))

	cp "$cd_workflow" "$mutation_dir/cd.yaml"
	cp "$release_workflow" "$mutation_dir/release.yaml"
	cp "$template_sync_workflow" "$mutation_dir/template-sync.yaml"
	cp "$validation_workflow" "$mutation_dir/validation.yaml"
	cp "$readme" "$mutation_dir/README.md"
	cp "$template_sync_ignore" "$mutation_dir/templatesyncignore"
	cp "$dependabot_config" "$mutation_dir/dependabot.yml"

	for pair in \
		"cd.yaml|.jobs.publish.uses|publish-app" \
		"release.yaml|.jobs.release.uses|create-release" \
		"template-sync.yaml|.jobs.\"template-sync\".uses|template-sync"; do
		mutant_file=${pair%%|*}
		rest=${pair#*|}
		mutant_path=${rest%%|*}
		mutant_workflow=${rest##*|}
		yq eval \
			"${mutant_path} = \"devantler-tech/actions/.github/workflows/${mutant_workflow}.yaml@${ref}\" |
			 ${mutant_path} line_comment = \"${version}\"" \
			"$mutation_dir/$mutant_file" > "$mutation_dir/mutant.yaml"
		mv "$mutation_dir/mutant.yaml" "$mutation_dir/$mutant_file"
	done

	if (validate_contract \
		"$mutation_dir/cd.yaml" \
		"$mutation_dir/release.yaml" \
		"$mutation_dir/template-sync.yaml" \
		"$mutation_dir/validation.yaml" \
		"$mutation_dir/README.md" \
		"$mutation_dir/templatesyncignore" \
		"$mutation_dir/dependabot.yml") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_mutation 'publish caller rolled back while the others stay current' cd \
	'.jobs.publish.uses = "devantler-tech/actions/.github/workflows/publish-app.yaml@b089a1b041cb86af22cdc57de58a4d7d258dcc32"'
run_mutation 'release caller rolled back while the others stay current' release \
	'.jobs.release.uses = "devantler-tech/actions/.github/workflows/create-release.yaml@b089a1b041cb86af22cdc57de58a4d7d258dcc32"'
run_fleet_mutation 'whole fleet rolled back below the reviewed floor' \
	'b089a1b041cb86af22cdc57de58a4d7d258dcc32' 'v13.1.1'
run_fleet_mutation 'whole fleet rolled back to the v13.0.7 state #149 recorded' \
	'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 'v13.0.7'
run_fleet_mutation 'version comment stripped from every pin' \
	'd72ecd5e8b680c2066a490a2b761a8913c454575' ''
run_fleet_mutation 'version comment made unparseable on every pin' \
	'd72ecd5e8b680c2066a490a2b761a8913c454575' 'vLATEST.x.y'
run_fleet_mutation 'version comment carrying a fourth component on every pin' \
	'd72ecd5e8b680c2066a490a2b761a8913c454575' 'v13.1.3.0'


printf 'PASS: tenant workflow caller contract (happy path + %s safety mutations)\n' "$mutations_run"
