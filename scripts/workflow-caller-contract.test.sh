#!/usr/bin/env sh

set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
cd_workflow=$repo_root/.github/workflows/cd.yaml
release_workflow=$repo_root/.github/workflows/release.yaml
template_sync_workflow=$repo_root/.github/workflows/template-sync.yaml
validation_workflow=$repo_root/.github/workflows/validate-scaffold.yaml
tenant_ci_workflow=$repo_root/.github/workflows/ci.yaml
reference=$repo_root/docs/REFERENCE.md
template_sync_ignore=$repo_root/.templatesyncignore
dependabot_config=$repo_root/.github/dependabot.yml
portable_contract=$repo_root/scripts/workflow-caller-pin-contract.test.sh

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

# A repository of its own, so only the ignore file under test applies when tenant_ignored asks git.
ignore_probe=$(mktemp -d)
mutation_dir=
trap 'rm -rf "$ignore_probe" ${mutation_dir:+"$mutation_dir"}' EXIT
git init -q --template= "$ignore_probe" ||
	fail 'cannot create the repository that evaluates .templatesyncignore'

# tenant_ignored succeeds when <ignore-file> makes template sync skip <path>, read with .gitignore rules
# (wildcards and negation included) as the file's header documents.
tenant_ignored() {
	case "$1" in
	/*) rules=$1 ;;
	*) rules=$PWD/$1 ;;
	esac
	status=0
	git -C "$ignore_probe" -c core.excludesFile="$rules" check-ignore --no-index -q -- "$2" || status=$?
	case "$status" in
	0) return 0 ;;
	1) return 1 ;;
	*) fail "cannot evaluate $1 for $2" ;;
	esac
}

[ -f "$portable_contract" ] ||
	fail 'the portable workflow-caller pin contract is missing'
grep -Fqx 'scripts/workflow-caller-contract.test.sh' "$template_sync_ignore" ||
	fail 'the scaffold-only workflow-caller contract must stay tenant-ignored'
if grep -Fqx 'scripts/workflow-caller-pin-contract.test.sh' "$template_sync_ignore"; then
	fail 'the portable workflow-caller pin contract must reach tenants through template sync'
fi
grep -Fq "\`scripts/workflow-caller-pin-contract.test.sh\`" "$reference" ||
	fail 'reference ownership table lacks the portable workflow-caller pin contract'
grep -Fq 'sh scripts/workflow-caller-pin-contract.test.sh' "$reference" ||
	fail 'reference local validation lacks the portable workflow-caller pin contract'
yq eval -e '
	[
		.jobs."workflow-caller-pins".steps[]
		| select((.run // "") == "sh scripts/workflow-caller-pin-contract.test.sh")
	] | length == 1
' "$tenant_ci_workflow" >/dev/null ||
	fail 'tenant CI must invoke the portable workflow-caller pin contract'
yq eval -e '
	.jobs."ci-required-checks".needs
	| [.[] | select(. == "workflow-caller-pins")] | length == 1
' "$tenant_ci_workflow" >/dev/null ||
	fail 'tenant required checks must depend on the portable workflow-caller pin contract'

validate_contract() {
	cd_file=$1
	release_file=$2
	template_sync_file=$3
	validation_file=$4
	reference_file=$5
	ignore_file=$6
	dependabot_file=$7

	sh "$portable_contract" --validate "$cd_file" "$release_file" "$template_sync_file" ||
		fail 'the portable workflow-caller pin contract rejected the caller set'

	yq eval -e '.jobs.publish.with."enable-caller-pin" == true' \
		"$cd_file" >/dev/null ||
		fail 'the publish caller must keep the producer-side ref guard enabled'

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
	# Security advisories are deliberately NOT asserted here. A Dependabot security group combines
	# only the dependencies that have an advisory, so it cannot force the unaffected callers to move
	# and therefore cannot deliver this invariant — asserting it would enforce a guarantee it does
	# not make. The config still declares one because it helps when advisories coincide. A PARTIAL
	# advisory bump is handled by a MANUAL escalation, not by anything here: this test deliberately
	# does not assert that path, and no workflow implements it, so the remedy is an engineer adapting
	# the partial pull request — behind a draft fence and a fresh exact-head review, as AGENTS.md
	# prescribes for a bot PR that cannot finish on its own — to move all three callers to one
	# reviewed SHA. The escalation's trigger, actor and action are written out in
	# `.github/dependabot.yml` beside the group itself.
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

	# Tenants that wire the publish-pin check into their required CI run its test there too, so both
	# must keep reaching tenants through template sync and be documented as template-owned.
	owned_table=$(awk '
		/^\*\*Owned by the template / { found = 1; next }
		found && /^\*\*/ { exit }
		found { print }
	' "$reference_file")
	[ -n "$owned_table" ] || fail 'reference lacks the template-owned table'
	for tenant_run in scripts/publish-pin-approved.sh scripts/publish-pin-approved.test.sh; do
		if tenant_ignored "$ignore_file" "$tenant_run"; then
			fail "tenants run $tenant_run in their CI, so it must not be tenant-ignored"
		fi
		printf '%s\n' "$owned_table" | grep -Fq "\`$tenant_run\`" ||
			fail "reference template-owned table lacks $tenant_run"
	done
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 8 ] ||
		fail 'usage: workflow-caller-contract.test.sh --validate <cd> <release> <template-sync> <validation> <reference> <ignore> <dependabot>'
	validate_contract "$2" "$3" "$4" "$5" "$6" "$7" "$8"
	exit 0
fi

validate_contract \
	"$cd_workflow" \
	"$release_workflow" \
	"$template_sync_workflow" \
	"$validation_workflow" \
	"$reference" \
	"$template_sync_ignore" \
	"$dependabot_config"

mutation_dir=$(mktemp -d)
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
	cp "$reference" "$mutation_dir/REFERENCE.md"
	cp "$template_sync_ignore" "$mutation_dir/templatesyncignore"
	cp "$dependabot_config" "$mutation_dir/dependabot.yml"

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
		"$mutation_dir/REFERENCE.md" \
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
run_mutation 'reference ownership table marker removed' reference \
	"/\`scripts\/workflow-caller-contract\.test\.sh\`/d"
run_mutation 'reference ignore marker removed' reference \
	'/^scripts\/workflow-caller-contract\.test\.sh$/d'
run_mutation 'reference local validation marker removed' reference \
	'/sh scripts\/workflow-caller-contract\.test\.sh/d'
run_mutation 'actual ownership marker removed' ignore \
	'/^scripts\/workflow-caller-contract\.test\.sh$/d'
run_mutation 'tenant-run publish-pin test tenant-ignored' ignore \
	'$a\
scripts/publish-pin-approved.test.sh'
run_mutation 'tenant-run publish-pin check tenant-ignored' ignore \
	'$a\
scripts/publish-pin-approved.sh'
run_mutation 'reference ownership row for the publish-pin test removed' reference \
	"/\`scripts\/publish-pin-approved\.test\.sh\`/d"
run_mutation 'publish-pin files tenant-ignored by a wildcard' ignore \
	'$a\
scripts/publish-pin-approved*'
run_mutation 'publish-pin row moved to the scaffold-time table' reference \
	'/^| `scripts\/publish-pin-approved\.sh`/{
h
d
}
/^| `scripts\/agent-instructions\.test\.sh`/G'
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
	cp "$reference" "$mutation_dir/REFERENCE.md"
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
		"$mutation_dir/REFERENCE.md" \
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
