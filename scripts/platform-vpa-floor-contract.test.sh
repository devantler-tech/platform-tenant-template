#!/usr/bin/env sh
# Pin the Platform VPA-floor validation into the scaffold workflow and tenant
# ownership boundary so a generated-policy drift cannot pass silently.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
workflow=$repo_root/.github/workflows/validate-scaffold.yaml
runtime=$repo_root/scripts/platform-vpa-floor.test.sh
readme=$repo_root/README.md
template_sync_ignore=$repo_root/.templatesyncignore

# Report a structural contract violation and stop the current validation path.
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# Validate the workflow, runtime, documentation, and ownership markers as one contract.
validate_contract() {
	workflow_file=$1
	runtime_file=$2
	readme_file=$3
	ignore_file=$4

	[ -f "$runtime_file" ] || fail "Platform VPA-floor runtime is missing"

	# Consume live Platform main read-only, limited to the policy catalogue that
	# supplies the generated VPA floor.
	# shellcheck disable=SC2016
	yq eval -e '
		[.jobs.admissibility.steps[]
			| select(.with.repository == "devantler-tech/platform")
			| select(
				(.uses | test("^actions/checkout@[0-9a-f]{40}$"))
				and .with.path == ".platform"
				and .with."persist-credentials" == false
				and (.with | has("ref") | not)
				and ((.with."sparse-checkout" | split("\n") | map(select(. != "")))
					| contains(["k8s/bases/infrastructure/cluster-policies"]))
			)
		] | length == 1
	' "$workflow_file" >/dev/null ||
		fail "Platform VPA-floor checkout is missing or mutable"
	# shellcheck disable=SC2016
	yq eval -e '
		[.jobs.admissibility.steps[] | select(
			(.run // "") == "sh scripts/platform-vpa-floor.test.sh"
			and ((has("if") or has("continue-on-error")) | not)
		)] | length == 1
	' "$workflow_file" >/dev/null ||
		fail "Platform VPA-floor runtime step is missing or conditional"
	# shellcheck disable=SC2016
	yq eval -e '
		[.jobs."validate-scaffold".steps[] | select(
			(.run // "") == "sh scripts/platform-vpa-floor-contract.test.sh"
			and ((has("if") or has("continue-on-error")) | not)
		)] | length == 1
	' "$workflow_file" >/dev/null ||
		fail "Platform VPA-floor contract step is missing or conditional"

	for needle in \
		'generate-vpa-for-deployment' \
		'autoscaling.k8s.io/v1' \
		'VerticalPodAutoscaler' \
		'minAllowed' \
		'resources.requests.cpu' \
		'millicores' \
		'validate_vpa_floor' \
		'run_mutation' \
		'scaffold request lowered below the Platform floor' \
		'Platform Deployment VPA rule removed' \
		'Platform floor raised above the scaffold request' \
		'Platform Deployment VPA rule duplicated' \
		'Platform Deployment VPA rule duplicated under another name' \
		'Platform CPU floor removed' \
		'Platform CPU floor changed to a noncanonical quantity' \
		'scaffold application container duplicated'
	do
		grep -Fq -- "$needle" "$runtime_file" ||
			fail "Platform VPA-floor runtime lacks: $needle"
	done

	owned_ignore_block=$(awk '
		/^\*\*Yours \(list these in `\.templatesyncignore`\):\*\*$/ { found = 1; next }
		found && /^```gitignore$/ { inside = 1; next }
		inside && /^```$/ { exit }
		inside { print }
	' "$readme_file")
	for scaffold_path in \
		'scripts/platform-vpa-floor.test.sh' \
		'scripts/platform-vpa-floor-contract.test.sh'
	do
		printf '%s\n' "$owned_ignore_block" | grep -Fxq -- "$scaffold_path" ||
			fail "README ignore example lacks: $scaffold_path"
		grep -Fxq -- "$scaffold_path" "$ignore_file" ||
			fail ".templatesyncignore lacks: $scaffold_path"
	done

	# shellcheck disable=SC2016
	grep -Fq '`scripts/platform-vpa-floor*.test.sh`' "$readme_file" ||
		fail "README ownership table lacks the Platform VPA-floor contract"
	grep -Fq 'sh scripts/platform-vpa-floor-contract.test.sh' "$readme_file" ||
		fail "README local validation lacks the Platform VPA-floor contract"
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 5 ] ||
		fail "usage: $0 --validate <workflow> <runtime> <readme> <ignore>"
	validate_contract "$2" "$3" "$4" "$5"
	exit 0
fi

validate_contract "$workflow" "$runtime" "$readme" "$template_sync_ignore"

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT

# Apply one isolated mutation and require the structural validator to reject it.
run_mutation() {
	description=$1
	workflow_mutation=$2
	runtime_mutation=$3
	readme_mutation=${4:-}
	ignore_mutation=${5:-}

	cp "$workflow" "$mutation_dir/workflow.yaml"
	cp "$runtime" "$mutation_dir/runtime.sh"
	cp "$readme" "$mutation_dir/README.md"
	cp "$template_sync_ignore" "$mutation_dir/templatesyncignore"

	if [ -n "$workflow_mutation" ]; then
		yq eval "$workflow_mutation" "$mutation_dir/workflow.yaml" > "$mutation_dir/workflow-mutant.yaml"
		mv "$mutation_dir/workflow-mutant.yaml" "$mutation_dir/workflow.yaml"
	fi
	if [ -n "$runtime_mutation" ]; then
		sed "$runtime_mutation" "$mutation_dir/runtime.sh" > "$mutation_dir/runtime-mutant.sh"
		mv "$mutation_dir/runtime-mutant.sh" "$mutation_dir/runtime.sh"
	fi
	if [ -n "$readme_mutation" ]; then
		sed "$readme_mutation" "$mutation_dir/README.md" > "$mutation_dir/readme-mutant.md"
		mv "$mutation_dir/readme-mutant.md" "$mutation_dir/README.md"
	fi
	if [ -n "$ignore_mutation" ]; then
		sed "$ignore_mutation" "$mutation_dir/templatesyncignore" > "$mutation_dir/ignore-mutant"
		mv "$mutation_dir/ignore-mutant" "$mutation_dir/templatesyncignore"
	fi

	if (validate_contract \
		"$mutation_dir/workflow.yaml" \
		"$mutation_dir/runtime.sh" \
		"$mutation_dir/README.md" \
		"$mutation_dir/templatesyncignore") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_mutation "live VPA-floor invocation removed" \
	'del(.jobs.admissibility.steps[] | select(.run == "sh scripts/platform-vpa-floor.test.sh"))' ''
run_mutation "live VPA-floor invocation made conditional" \
	'(.jobs.admissibility.steps[] | select(.run == "sh scripts/platform-vpa-floor.test.sh")).if = "false"' ''
run_mutation "contract invocation removed" \
	'del(.jobs."validate-scaffold".steps[] | select(.run == "sh scripts/platform-vpa-floor-contract.test.sh"))' ''
run_mutation "Platform policy checkout removed" \
	'(.jobs.admissibility.steps[] | select(.with.repository == "devantler-tech/platform").with."sparse-checkout") |= sub("k8s/bases/infrastructure/cluster-policies\\n"; "")' ''
run_mutation "Platform checkout pinned away from live main" \
	'(.jobs.admissibility.steps[] | select(.with.repository == "devantler-tech/platform").with.ref) = "stale-ref"' ''
run_mutation "runtime comparison removed" '' '/resources.requests.cpu/d'
run_mutation "runtime mutation controls removed" '' '/run_mutation/d'
run_mutation "Platform CPU floor removal control removed" '' \
	'/^run_mutation "Platform CPU floor removed"/{N;d;}'
# shellcheck disable=SC2016
run_mutation "README ownership marker removed" '' '' \
	'/`scripts\/platform-vpa-floor\*\.test\.sh`/d'
run_mutation "README local validation marker removed" '' '' \
	'/sh scripts\/platform-vpa-floor-contract\.test\.sh/d'
run_mutation "README runtime ownership marker removed" '' '' \
	'/^scripts\/platform-vpa-floor\.test\.sh$/d'
run_mutation ".templatesyncignore contract marker removed" '' '' '' \
	'/^scripts\/platform-vpa-floor-contract\.test\.sh$/d'

echo "PASS: Platform VPA-floor structural contract (happy path + 12 safety mutations)"
