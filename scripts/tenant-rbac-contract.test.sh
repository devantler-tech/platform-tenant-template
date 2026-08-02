#!/usr/bin/env sh
# Pin the live Platform tenant-RBAC gate copied by this template.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
workflow=$repo_root/.github/workflows/validate-scaffold.yaml
runtime=$repo_root/scripts/tenant-rbac.test.sh
pod_security_runtime=$repo_root/scripts/pod-security-admission.test.sh
readme=$repo_root/README.md
template_sync_ignore=$repo_root/.templatesyncignore

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

validate_contract() {
	workflow_file=$1
	runtime_file=$2
	pod_security_file=$3
	readme_file=$4
	ignore_file=$5

	[ -f "$runtime_file" ] || fail "tenant RBAC runtime is missing"

	expected_if=$(printf '%s' \
		"github.repository == 'devantler-tech/platform-tenant-template'")
	export expected_if
	# shellcheck disable=SC2016
	if ! yq eval -e '
		.jobs."pod-security-admission" as $job
		| ($job.if == strenv(expected_if)
		and $job.needs == null
		and ($job | has("continue-on-error") | not)
		and ([.jobs."validate-scaffold".steps[] | select(
			(.run // "") == "sh scripts/tenant-rbac-contract.test.sh"
			and ((has("if") or has("continue-on-error")) | not)
		)] | length == 1)
		and ([$job.steps[] | select(has("if") or has("continue-on-error"))] | length == 0)
		and ([$job.steps[] | select(
			(.uses | test("^actions/checkout@[0-9a-f]{40}$"))
			and .with.repository == "devantler-tech/platform"
			and .with.path == ".platform"
			and .with."sparse-checkout" == "k8s/bases/infrastructure/cluster-roles"
			and .with."persist-credentials" == false
		)] | length == 1))
	' "$workflow_file" >/dev/null; then
		fail "tenant RBAC workflow checkout is missing, conditional, or mutable"
	fi

	# The contract intentionally matches the literal runtime expression.
	# shellcheck disable=SC2016
	grep -Fq 'sh "$repo_root/scripts/tenant-rbac.test.sh"' "$pod_security_file" ||
		fail "Pod Security runtime does not exercise tenant RBAC before cluster cleanup"

	for needle in \
		'tenant-edit.yaml' \
		'tenant-base-edit.yaml' \
		'cilium-tenant-edit.yaml' \
		'cnpg-tenant-edit.yaml' \
		'external-secrets-tenant-edit.yaml' \
		'gateway-tenant-edit.yaml' \
		'authorization.k8s.io/v1' \
		'kind: "SubjectAccessReview"' \
		'SubjectAccessReview request failed' \
		'SubjectAccessReview response lacks boolean status.allowed' \
		'for aggregation_resource in' \
		'system:serviceaccount:tenant-rbac-test:tenant-reconciler' \
		'get list watch create patch update delete' \
		'deployments.apps' \
		'services' \
		'poddisruptionbudgets.policy' \
		'ciliumnetworkpolicies.cilium.io' \
		'externalsecrets.external-secrets.io' \
		'secretstores.external-secrets.io' \
		'httproutes.gateway.networking.k8s.io' \
		'clusters.postgresql.cnpg.io' \
		'clustersecretstores.external-secrets.io' \
		'ciliumclusterwidenetworkpolicies.cilium.io' \
		'namespaces' \
		'clusterroles.rbac.authorization.k8s.io' \
		'pods/exec'
	do
		grep -Fq -- "$needle" "$runtime_file" ||
			fail "tenant RBAC runtime lacks: $needle"
	done

	owned_ignore_block=$(awk '
		/^\*\*Yours \(list these in `\.templatesyncignore`\):\*\*$/ { found = 1; next }
		found && /^```gitignore$/ { inside = 1; next }
		inside && /^```$/ { exit }
		inside { print }
	' "$readme_file")
	for scaffold_path in \
		'scripts/tenant-rbac.test.sh' \
		'scripts/tenant-rbac-contract.test.sh'
	do
		printf '%s\n' "$owned_ignore_block" | grep -Fxq -- "$scaffold_path" ||
			fail "README ignore example lacks: $scaffold_path"
		grep -Fxq -- "$scaffold_path" "$ignore_file" ||
			fail ".templatesyncignore lacks: $scaffold_path"
	done
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 6 ] ||
		fail "usage: $0 --validate <workflow> <runtime> <pod-security-runtime> <readme> <ignore>"
	validate_contract "$2" "$3" "$4" "$5" "$6"
	exit 0
fi

validate_contract "$workflow" "$runtime" "$pod_security_runtime" "$readme" "$template_sync_ignore"

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT

run_mutation() {
	description=$1
	workflow_mutation=$2
	runtime_mutation=$3
	pod_security_mutation=$4
	readme_mutation=${5:-}
	ignore_mutation=${6:-}

	cp "$workflow" "$mutation_dir/workflow.yaml"
	cp "$runtime" "$mutation_dir/runtime.sh"
	cp "$pod_security_runtime" "$mutation_dir/pod-security.sh"
	cp "$readme" "$mutation_dir/README.md"
	cp "$template_sync_ignore" "$mutation_dir/templatesyncignore"

	if [ -n "$workflow_mutation" ]; then
		yq eval "$workflow_mutation" "$mutation_dir/workflow.yaml" > "$mutation_dir/mutant.yaml"
		mv "$mutation_dir/mutant.yaml" "$mutation_dir/workflow.yaml"
	fi
	if [ -n "$runtime_mutation" ]; then
		sed "$runtime_mutation" "$mutation_dir/runtime.sh" > "$mutation_dir/mutant.sh"
		mv "$mutation_dir/mutant.sh" "$mutation_dir/runtime.sh"
	fi
	if [ -n "$pod_security_mutation" ]; then
		sed "$pod_security_mutation" "$mutation_dir/pod-security.sh" > "$mutation_dir/mutant.sh"
		mv "$mutation_dir/mutant.sh" "$mutation_dir/pod-security.sh"
	fi
	if [ -n "$readme_mutation" ]; then
		sed "$readme_mutation" "$mutation_dir/README.md" > "$mutation_dir/mutant.md"
		mv "$mutation_dir/mutant.md" "$mutation_dir/README.md"
	fi
	if [ -n "$ignore_mutation" ]; then
		sed "$ignore_mutation" "$mutation_dir/templatesyncignore" > "$mutation_dir/mutant.ignore"
		mv "$mutation_dir/mutant.ignore" "$mutation_dir/templatesyncignore"
	fi

	if (validate_contract \
		"$mutation_dir/workflow.yaml" \
		"$mutation_dir/runtime.sh" \
		"$mutation_dir/pod-security.sh" \
		"$mutation_dir/README.md" \
		"$mutation_dir/templatesyncignore") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_mutation "Platform checkout removed" \
	'del(.jobs."pod-security-admission".steps[] | select(.with.repository == "devantler-tech/platform"))' '' ''
run_mutation "contract invocation removed" \
	'del(.jobs."validate-scaffold".steps[] | select(.run == "sh scripts/tenant-rbac-contract.test.sh"))' '' ''
run_mutation "cluster-role checkout widened" \
	'.jobs."pod-security-admission".steps[] |= (select(.with.repository == "devantler-tech/platform").with."sparse-checkout" = "k8s/bases/infrastructure")' '' ''
run_mutation "aggregate role fragment removed" '' \
	'/tenant-base-edit\.yaml/d' ''
run_mutation "required verb removed" '' \
	's/get list watch create patch update delete/get list watch create patch update/' ''
run_mutation "resource mapping removed" '' \
	'/httproutes\.gateway\.networking\.k8s\.io/d' ''
run_mutation "authorization invocation removed" '' \
	'/kind: "SubjectAccessReview"/d' ''
run_mutation "authorization execution error hidden" '' \
	'/SubjectAccessReview request failed/d' ''
run_mutation "authorization response error hidden" '' \
	'/SubjectAccessReview response lacks boolean status\.allowed/d' ''
run_mutation "aggregate readiness loop removed" '' \
	'/for aggregation_resource in/d' ''
run_mutation "RBAC runtime call removed" '' '' \
	'/tenant-rbac\.test\.sh/d'
run_mutation "denial boundary removed" '' \
	'/pods\/exec/d' ''
run_mutation "documented ignore removed" '' '' '' \
	'/^scripts\/tenant-rbac\.test\.sh$/d'
run_mutation "actual ignore removed" '' '' '' '' \
	'/^scripts\/tenant-rbac\.test\.sh$/d'

fake_bin=$mutation_dir/fake-bin
fake_roles=$mutation_dir/cluster-roles
mkdir -p "$fake_bin" "$fake_roles"
for role_file in \
	tenant-edit.yaml \
	tenant-base-edit.yaml \
	cilium-tenant-edit.yaml \
	cnpg-tenant-edit.yaml \
	external-secrets-tenant-edit.yaml \
	gateway-tenant-edit.yaml
do
	: > "$fake_roles/$role_file"
done

# These are literal lines for the generated fake kubectl, not this shell.
# shellcheck disable=SC2016
{
	printf '%s\n' '#!/usr/bin/env sh' 'set -eu'
	printf '%s\n' 'if [ "${1:-}" = "kustomize" ]; then exec "$REAL_KUBECTL" "$@"; fi'
	printf '%s\n' 'if [ "${1:-}" = "create" ] && [ "${2:-}" = "-f" ]; then'
	printf '%s\n' '  case "$FAKE_SAR_MODE" in'
	printf '%s\n' '    request-error) exit 1 ;;'
	printf '%s\n' '    malformed) printf "%s\n" "{}" ;;'
	printf '%s\n' '    partial)'
	printf '%s\n' '      resource=$(jq -r ".spec.resourceAttributes.resource" "$3")'
	printf '%s\n' '      [ "$resource" = "deployments" ] && allowed=true || allowed=false'
	printf '%s\n' '      printf "{\"status\":{\"allowed\":%s}}\n" "$allowed"'
	printf '%s\n' '      ;;'
	printf '%s\n' '  esac'
	printf '%s\n' 'fi'
	printf '%s\n' 'exit 0'
} > "$fake_bin/kubectl"
printf '%s\n' '#!/usr/bin/env sh' 'exit 0' > "$fake_bin/sleep"
chmod +x "$fake_bin/kubectl" "$fake_bin/sleep"
real_kubectl=$(command -v kubectl)

exercise_runtime_failure() {
	mode=$1
	expected_error=$2
	if output=$(PATH="$fake_bin:$PATH" \
		REAL_KUBECTL="$real_kubectl" \
		FAKE_SAR_MODE="$mode" \
		PLATFORM_CLUSTER_ROLES_DIR="$fake_roles" \
		sh "$runtime" 2>&1); then
		fail "runtime unexpectedly passed the $mode SubjectAccessReview control"
	fi
	printf '%s\n' "$output" | grep -Fq -- "$expected_error" ||
		fail "runtime did not fail closed for $mode SubjectAccessReview control"
}

exercise_runtime_failure request-error 'SubjectAccessReview request failed'
exercise_runtime_failure malformed 'SubjectAccessReview response lacks boolean status.allowed'
exercise_runtime_failure partial 'tenant-edit aggregation did not grant every role fragment'

echo "PASS: tenant RBAC contract (happy path + 14 safety mutations + 3 runtime error controls)"
