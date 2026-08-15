#!/usr/bin/env sh
# Pin the signed publisher and live Platform envelope that deliver this workload.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
workflow=$repo_root/.github/workflows/validate-scaffold.yaml
runtime=$repo_root/scripts/platform-tenant-envelope.test.sh
pod_security_runtime=$repo_root/scripts/pod-security-admission.test.sh
rbac_runtime=$repo_root/scripts/tenant-rbac.test.sh
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
	rbac_file=$4
	readme_file=$5
	ignore_file=$6

	[ -f "$runtime_file" ] || fail "Platform tenant-envelope runtime is missing"

	# Keep these assertions separate: yq's boolean operator changes the input
	# context of its right-hand expression, which can hide a missing job step.
	# shellcheck disable=SC2016
	yq eval -e '
		[.jobs.admissibility.steps[]
			| select(.with.repository == "devantler-tech/platform")
			| select(
				(.uses | test("^actions/checkout@[0-9a-f]{40}$"))
				and .with.path == ".platform"
				and .with."persist-credentials" == false
				and ((.with."sparse-checkout" | split("\n") | join("|")) ==
					"k8s/bases/infrastructure/cluster-policies|" +
					"k8s/bases/infrastructure/resource-graph-definitions/tenant|" +
					"k8s/bases/infrastructure/vault-config|" +
					"k8s/bases/apps/ascoachingogvaner|" +
					"k8s/clusters/local/bootstrap/config-map.yaml|" +
					"k8s/clusters/prod/bootstrap/config-map.yaml|")
			)
		] | length == 1
	' "$workflow_file" >/dev/null ||
		fail "Platform tenant-envelope checkout is incomplete or mutable"
	# shellcheck disable=SC2016
	yq eval -e '
		[.jobs.admissibility.steps[] | select(
			(.run // "") == "sh scripts/platform-tenant-envelope.test.sh"
			and ((has("if") or has("continue-on-error")) | not)
		)] | length == 1
	' "$workflow_file" >/dev/null ||
		fail "Platform tenant-envelope runtime step is missing or conditional"
	# shellcheck disable=SC2016
	yq eval -e '
		[.jobs."validate-scaffold".steps[] | select(
			(.run // "") == "sh scripts/platform-tenant-envelope-contract.test.sh"
			and ((has("if") or has("continue-on-error")) | not)
		)] | length == 1
	' "$workflow_file" >/dev/null ||
		fail "Platform tenant-envelope contract step is missing or conditional"

	for needle in \
		'resource-graph-definitions/tenant/resource-graph-definition.yaml' \
		'k8s/bases/infrastructure/vault-config/job.yaml' \
		'k8s/bases/apps/ascoachingogvaner' \
		'deploy/secretstore.yaml' \
		'deploy/externalsecret.yaml' \
		'namespace.yaml' \
		'service-account.yaml' \
		'external-secret.yaml' \
		'oci-repository.yaml' \
		'role-binding-ascoachingogvaner.yaml' \
		'flux-kustomization.yaml' \
		'kustomization.yaml' \
		'tenantNamespace' \
		'ghcrAuth' \
		'ociRepository' \
		'kustomizationSops' \
		'includeWhen' \
		'app.kubernetes.io/managed-by' \
		'pod-security.kubernetes.io/enforce' \
		'pod-security.kubernetes.io/enforce-version' \
		'tenant-edit' \
		'imagePullSecrets' \
		'infrastructure/ghcr/auth' \
		'kubernetes.io/dockerconfigjson' \
		'matchOIDCIdentity' \
		'publish-app.yaml' \
		'serviceAccountName' \
		'sourceRef' \
		'targetNamespace' \
		'validate_openbao_authorization' \
		'OpenBao prefixed-role control did not mutate the baseline' \
		'secret/data/apps/' \
		'secret/metadata/apps/' \
		'bound_service_account_names' \
		'bound_service_account_namespaces' \
		'validate_platform' \
		'run_mutation'
	do
		grep -Fq -- "$needle" "$runtime_file" ||
			fail "Platform tenant-envelope runtime lacks: $needle"
	done
	# Match the runtime's literal variable reference.
	# shellcheck disable=SC2016
	[ "$(grep -Ec '^[[:space:]]*validate_publish_workflow "\$publish_workflow"$' "$runtime_file")" -eq 2 ] ||
		fail "Platform tenant-envelope runtime does not validate the publisher on every entry path"

	# The three existing gates model the same context independently. Keep their
	# shared identity assumptions explicit so they cannot silently diverge from
	# the Platform envelope that creates the namespace and reconciler.
	# shellcheck disable=SC2016
	yq eval -e '
		[.jobs.admissibility.steps[] | select(
			.id == "apply-admission-policies"
			and ((.run | split("app.kubernetes.io/managed-by") | length) == 3)
		)] | length == 1
	' "$workflow_file" >/dev/null ||
		fail "SecretStore admission no longer models both managed namespace contexts"
	grep -Fq 'pod-security.kubernetes.io/enforce' "$pod_security_file" ||
		fail "Pod Security runtime no longer models the restricted namespace label"
	grep -Fq 'tenant-edit' "$rbac_file" ||
		fail "tenant RBAC runtime no longer binds the tenant-edit ClusterRole"

	owned_ignore_block=$(awk '
		/^\*\*Yours \(list these in `\.templatesyncignore`\):\*\*$/ { found = 1; next }
		found && /^```gitignore$/ { inside = 1; next }
		inside && /^```$/ { exit }
		inside { print }
	' "$readme_file")
	for scaffold_path in \
		'scripts/platform-tenant-envelope.test.sh' \
		'scripts/platform-tenant-envelope-contract.test.sh'
	do
		printf '%s\n' "$owned_ignore_block" | grep -Fxq -- "$scaffold_path" ||
			fail "README ignore example lacks: $scaffold_path"
		grep -Fxq -- "$scaffold_path" "$ignore_file" ||
			fail ".templatesyncignore lacks: $scaffold_path"
	done
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 7 ] ||
		fail "usage: $0 --validate <workflow> <runtime> <pod-security-runtime> <rbac-runtime> <readme> <ignore>"
	validate_contract "$2" "$3" "$4" "$5" "$6" "$7"
	exit 0
fi

validate_contract \
	"$workflow" \
	"$runtime" \
	"$pod_security_runtime" \
	"$rbac_runtime" \
	"$readme" \
	"$template_sync_ignore"

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT
mutations_run=0

run_mutation() {
	mutations_run=$((mutations_run + 1))
	description=$1
	workflow_mutation=$2
	runtime_mutation=$3
	pod_security_mutation=${4:-}
	rbac_mutation=${5:-}
	readme_mutation=${6:-}
	ignore_mutation=${7:-}

	cp "$workflow" "$mutation_dir/workflow.yaml"
	cp "$runtime" "$mutation_dir/runtime.sh"
	cp "$pod_security_runtime" "$mutation_dir/pod-security.sh"
	cp "$rbac_runtime" "$mutation_dir/rbac.sh"
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
	if [ -n "$rbac_mutation" ]; then
		sed "$rbac_mutation" "$mutation_dir/rbac.sh" > "$mutation_dir/mutant.sh"
		mv "$mutation_dir/mutant.sh" "$mutation_dir/rbac.sh"
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
		"$mutation_dir/rbac.sh" \
		"$mutation_dir/README.md" \
		"$mutation_dir/templatesyncignore") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_mutation "Platform RGD checkout removed" \
	'(.jobs.admissibility.steps[] | select(.with.repository == "devantler-tech/platform").with."sparse-checkout") |= sub("k8s/bases/infrastructure/resource-graph-definitions/tenant\\n"; "")' ''
run_mutation "Platform OpenBao authorization checkout removed" \
	'(.jobs.admissibility.steps[] | select(.with.repository == "devantler-tech/platform").with."sparse-checkout") |= sub("k8s/bases/infrastructure/vault-config\\n"; "")' ''
run_mutation "live envelope invocation removed" \
	'del(.jobs.admissibility.steps[] | select(.run == "sh scripts/platform-tenant-envelope.test.sh"))' ''
run_mutation "contract invocation removed" \
	'del(.jobs."validate-scaffold".steps[] | select(.run == "sh scripts/platform-tenant-envelope-contract.test.sh"))' ''
run_mutation "SecretStore managed namespace context removed" \
	'(.jobs.admissibility.steps[] | select(.id == "apply-admission-policies").run) |= sub("app.kubernetes.io/managed-by"; "removed-label")' ''
run_mutation "SOPS variant validation removed" '' '/kustomizationSops/d'
run_mutation "target namespace validation removed" '' '/targetNamespace/d'
run_mutation "private artifact credential validation removed" '' '/ghcrAuth/d'
run_mutation "signed publisher validation removed" '' '/publish-app\.yaml/d'
run_mutation "OpenBao authorization validation removed" '' \
	'/validate_openbao_authorization/d'
run_mutation "publisher baseline invocation removed" '' \
	'/^[[:space:]]*validate_publish_workflow /d'
run_mutation "README tenant-envelope runtime marker removed" '' '' '' '' \
	'/^scripts\/platform-tenant-envelope\.test\.sh$/d'
run_mutation ".templatesyncignore tenant-envelope runtime marker removed" '' '' '' '' '' \
	'/^scripts\/platform-tenant-envelope\.test\.sh$/d'
run_mutation "Pod Security context removed" '' '' \
	'/pod-security\.kubernetes\.io\/enforce/d'
run_mutation "RBAC context removed" '' '' '' \
	'/tenant-edit/d'

echo "PASS: Platform tenant-envelope contract (happy path + ${mutations_run} safety mutations)"
