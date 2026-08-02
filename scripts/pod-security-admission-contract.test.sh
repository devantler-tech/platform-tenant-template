#!/usr/bin/env sh
# Pin the live Pod Security Admission gate copied by this template.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
workflow=$repo_root/.github/workflows/validate-scaffold.yaml
runtime=$repo_root/scripts/pod-security-admission.test.sh
readme=$repo_root/README.md

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

validate_contract() {
	workflow_file=$1
	runtime_file=$2
	readme_file=$3

	[ -f "$runtime_file" ] || fail "Pod Security admission runtime is missing"

	expected_if=$(printf '%s' \
		"github.repository == 'devantler-tech/platform-tenant-template'")
	export expected_if
	# The yq program is deliberately literal; only strenv(expected_if) supplies data.
	# shellcheck disable=SC2016
	if ! yq eval -e '
		.jobs."pod-security-admission" as $job
		| ($job.if == strenv(expected_if)
		and $job.needs == null
		and ($job | has("continue-on-error") | not)
		and $job.env.KIND_VERSION == "v0.32.0"
		and $job.env.KIND_NODE_IMAGE == "kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5"
		and $job.env.POD_SECURITY_VERSION == "v1.36"
		and ([$job.steps[] | select(has("if") or has("continue-on-error"))] | length == 0)
		and ([$job.steps[] | select(
			(.run // "") == "GOTOOLCHAIN=local go install \"sigs.k8s.io/kind@${KIND_VERSION}\""
		)] | length == 1)
		and ([$job.steps[] | select(
			(.run // "") == "sh scripts/pod-security-admission.test.sh"
		)] | length == 1))
	' "$workflow_file" >/dev/null; then
		fail "Pod Security admission workflow contract is incomplete or unpinned"
	fi

	for needle in \
		'pod-security.kubernetes.io/enforce' \
		'.kind = "Pod"' \
		'kubectl apply --server-side --dry-run=server' \
		'run-as-root' \
		'privilege-escalation' \
		'capability-add'
	do
		grep -Fq -- "$needle" "$runtime_file" ||
			fail "Pod Security admission runtime lacks: $needle"
	done

	owned_ignore_block=$(awk '
		/^\*\*Yours \(list these in `\.templatesyncignore`\):\*\*$/ { found = 1; next }
		found && /^```gitignore$/ { inside = 1; next }
		inside && /^```$/ { exit }
		inside { print }
	' "$readme_file")
	for scaffold_path in \
		'scripts/pod-security-admission.test.sh' \
		'scripts/pod-security-admission-contract.test.sh'
	do
		printf '%s\n' "$owned_ignore_block" | grep -Fxq -- "$scaffold_path" ||
			fail "README ignore example lacks: $scaffold_path"
	done
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 4 ] || fail "usage: $0 --validate <workflow> <runtime> <readme>"
	validate_contract "$2" "$3" "$4"
	exit 0
fi

validate_contract "$workflow" "$runtime" "$readme"

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT

run_mutation() {
	description=$1
	workflow_mutation=$2
	runtime_mutation=$3
	readme_mutation=${4:-}

	cp "$workflow" "$mutation_dir/workflow.yaml"
	cp "$runtime" "$mutation_dir/runtime.sh"
	cp "$readme" "$mutation_dir/README.md"

	if [ -n "$workflow_mutation" ]; then
		yq eval "$workflow_mutation" "$mutation_dir/workflow.yaml" > "$mutation_dir/mutant.yaml"
		mv "$mutation_dir/mutant.yaml" "$mutation_dir/workflow.yaml"
	fi
	if [ -n "$runtime_mutation" ]; then
		sed "$runtime_mutation" "$mutation_dir/runtime.sh" > "$mutation_dir/mutant.sh"
		mv "$mutation_dir/mutant.sh" "$mutation_dir/runtime.sh"
	fi
	if [ -n "$readme_mutation" ]; then
		sed "$readme_mutation" "$mutation_dir/README.md" > "$mutation_dir/mutant.md"
		mv "$mutation_dir/mutant.md" "$mutation_dir/README.md"
	fi

	if (validate_contract "$mutation_dir/workflow.yaml" "$mutation_dir/runtime.sh" "$mutation_dir/README.md") \
		>/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_mutation "job removed" 'del(.jobs."pod-security-admission")' ''
run_mutation "kind version unpinned" '.jobs."pod-security-admission".env.KIND_VERSION = "latest"' ''
run_mutation "server admission bypassed" '' 's/--server-side --dry-run=server/--dry-run=client/'
run_mutation "Pod conversion removed" '' 's/\.kind = "Pod"/.kind = "Deployment"/'
run_mutation "negative control removed" '' 's/capability-add/capability-removed/'
run_mutation "documented ignore removed" '' '' '/^scripts\/pod-security-admission\.test\.sh$/d'

echo "PASS: Pod Security admission contract (happy path + 6 safety mutations)"
