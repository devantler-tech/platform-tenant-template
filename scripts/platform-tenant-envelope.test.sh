#!/usr/bin/env sh
# Verify that the template publishes a signed private artifact and Platform main
# still supplies the credential, verification, and Flux envelope that consumes it.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
publish_workflow=$repo_root/.github/workflows/cd.yaml
expected_oidc_issuer='^https://token\.actions\.githubusercontent\.com$'
# Flux follows only stable X.Y.Z releases when a range carries this filter.
stable_semver_filter='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
# A yq predicate over an OCIRepository ref: a stable release range, optionally
# narrowed by exactly that filter, with no digest or tag that would freeze or float it.
# Inlined into each check: yq reads a boolean bound with `as $x` as false after `and`.
stable_stream='((tag == "!!map") and (((keys | sort | join(",")) == "semver") or ((keys | sort | join(",")) == "semver,semverFilter")) and ((.semver | tag) == "!!str") and (.semver | test("^>=(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$")) and ((has("semverFilter") | not) or .semverFilter == strenv(stable_semver_filter)))'
# The starter's producer identity, set once its signing frame is validated.
publisher_identity=''
# Platform trusts only a tenant's OWN release workflow on a release tag (ADR 0017,
# platform#6303): the tenant's repository followed by this tail. The semver part
# is the ksail release grammar, pre-releases included. Only this exact text is
# recognised; any other own-release shape is rejected, never interpreted.
own_release_prefix='^https://github\.com/devantler-tech/'
own_release_tail='/\.github/workflows/[^/]+\.ya?ml@refs/tags/v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?'
# A fixed sample repository instantiates the generic Tenant's dynamic name.
probe_repository=tenant-envelope-probe
export expected_oidc_issuer stable_semver_filter

# Report the failed invariant and stop the envelope check with a nonzero status.
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# Require an RFC 1123 DNS label: a repository name that needs no regex escape.
# The character list is spelled out because a range such as a-z can match
# other characters under some locales.
validate_dns_label() (
	label=$1
	if [ "${#label}" -lt 1 ] || [ "${#label}" -gt 63 ]; then
		exit 1
	fi
	case "$label" in
		*[!abcdefghijklmnopqrstuvwxyz0123456789-]*|-*|*-) exit 1 ;;
	esac
)

# Print the one anchored subject that trusts <repository>'s own release workflow.
own_release_subject() (
	validate_dns_label "$1" || exit 1
	printf '%s%s%s$\n' "$own_release_prefix" "$1" "$own_release_tail"
)

# Decode one CEL string literal as JSON, without evaluating CEL or treating its
# content as shell code. The literal must be exactly one quoted string, and
# controls are checked before the shell can strip a trailing newline or NUL.
decode_cel_string() (
	case "$1" in '"'*'"') ;; *) exit 1 ;; esac
	printf '%s' "$1" | jq -Rser 'fromjson | select(type == "string") | select(test("[[:space:][:cntrl:]]") | not)'
)

# Read the generic Tenant's subject without executing CEL. The only accepted
# expression joins two literals around the regex-escaped Tenant name: the
# organization prefix before it, the own-release tail and end anchor after it.
# Print that rule instantiated for the fixed probe repository.
# The CEL delimiters below are literal text, never shell expansions.
# shellcheck disable=SC2016
generic_own_release_subject() (
	subject=$1
	name_expression=' + schema.spec.name.replace(".", "\\.").replace("-", "\\-") + '
	case "$subject" in
		'${'*"$name_expression"*'}') ;;
		*) exit 1 ;;
	esac
	encoded=${subject#'${'}
	encoded=${encoded%'}'}
	before=$(decode_cel_string "${encoded%%"$name_expression"*}") || exit 1
	after=$(decode_cel_string "${encoded#*"$name_expression"}") || exit 1
	[ "$before" = "$own_release_prefix" ] || exit 1
	[ "$after" = "$own_release_tail\$" ] || exit 1
	own_release_subject "$probe_repository"
)

# Bind the tag-only publishing job to the minimal, credential-free frame its
# own-release signature relies on: the signer is this repository's cd.yaml on a
# release tag, whatever revision of the publish-app action it runs.
validate_publish_workflow() {
	workflow_file=$1
	[ -f "$workflow_file" ] || fail "tenant publish workflow is missing: $workflow_file"
	yq eval-all -e '[.] | length == 1' "$workflow_file" >/dev/null ||
		fail "tenant publish workflow must contain exactly one YAML document"
	# Workflow-level env and defaults can also change the action's execution.
	# shellcheck disable=SC2016
	publish_manifest_choice='${{ hashFiles('\''deploy/base/deployment.yaml'\'') != '\'''\'' && '\''base/deployment.yaml'\'' || '\''deployment.yaml'\'' }}' \
		yq eval -e '
		(keys - ["name", "on", "permissions", "jobs"] | length) == 0
		and (.permissions | length) == 0
		and (.["on"] | keys | join(",")) == "push"
		and (.["on"].push | keys | join(",")) == "tags"
		and (.["on"].push.tags | length) == 1
		and .["on"].push.tags[0] == "v*"
		and (.jobs | keys | join(",")) == "publish"
		and (.jobs.publish | keys | sort | join(",")) == "concurrency,if,name,permissions,runs-on,steps,timeout-minutes"
		and .jobs.publish.if == "github.repository_id != '\''1253884448'\''"
		and .jobs.publish."runs-on" == "ubuntu-latest"
		and .jobs.publish."timeout-minutes" == 60
		and (.jobs.publish.concurrency.group == "publish-${{ github.repository }}"
			or .jobs.publish.concurrency.group == "publish-verified-${{ github.repository }}")
		and .jobs.publish.concurrency."cancel-in-progress" == false
		and (.jobs.publish.permissions | length) == 3
		and .jobs.publish.permissions.contents == "read"
		and .jobs.publish.permissions.packages == "write"
		and .jobs.publish.permissions."id-token" == "write"
		and (.jobs.publish.steps | length) == 3
		and (.jobs.publish.steps[0] | keys | sort | join(",")) == "name,uses,with"
		and (.jobs.publish.steps[0].uses | test("^step-security/harden-runner@[0-9a-f]{40}$"))
		and (.jobs.publish.steps[0].with | length) == 1
		and .jobs.publish.steps[0].with."egress-policy" == "audit"
		and (.jobs.publish.steps[1] | keys | sort | join(",")) == "name,uses,with"
		and (.jobs.publish.steps[1].uses | test("^actions/checkout@[0-9a-f]{40}$"))
		and (.jobs.publish.steps[1].with | length) == 1
		and .jobs.publish.steps[1].with."persist-credentials" == false
		and (.jobs.publish.steps[2] | keys | sort | join(",")) == "id,name,uses,with"
		and .jobs.publish.steps[2].id == "publish"
		and (.jobs.publish.steps[2].uses | test("^devantler-tech/[.]github/actions/publish-app@[0-9a-f]{40}$"))
		and (.jobs.publish.steps[2].with | keys | sort | join(",")) == "app-manifest,app-name"
		and .jobs.publish.steps[2].with."app-name" == "${{ github.event.repository.name }}"
		and (.jobs.publish.steps[2].with."app-manifest" == "base/deployment.yaml"
			or .jobs.publish.steps[2].with."app-manifest" == "deployment.yaml"
			or .jobs.publish.steps[2].with."app-manifest" == strenv(publish_manifest_choice))
	' "$workflow_file" >/dev/null ||
		fail "tenant publish workflow no longer has the minimal own-release signing frame"
	# This exercises the decoded matcher with a fixed sample release, without
	# claiming a real release was signed, admitted or reconciled.
	publisher_identity=https://github.com/devantler-tech/$probe_repository/.github/workflows/cd.yaml@refs/tags/v1.2.3
}

# Require the renamed tenant's exact OpenBao policy and Kubernetes-auth binding.
validate_openbao_authorization() (
	platform_root=$1
	scaffold_root=$2
	tenant_name=$3
	vault_config=$platform_root/k8s/bases/infrastructure/vault-config/job.yaml
	rename_script=$scaffold_root/scripts/rename-placeholders.sh

	for required_file in \
		"$vault_config" \
		"$rename_script" \
		"$scaffold_root/deploy/secretstore.yaml" \
		"$scaffold_root/deploy/externalsecret.yaml"
	do
		[ -f "$required_file" ] || fail "OpenBao authorization source is missing: $required_file"
	done

	renamed_scaffold=$(mktemp -d)
	trap 'rm -rf "$renamed_scaffold"' EXIT
	mkdir -p "$renamed_scaffold/scripts"
	cp -R "$scaffold_root/deploy" "$renamed_scaffold/deploy"
	cp "$rename_script" "$renamed_scaffold/scripts/rename-placeholders.sh"
	sh "$renamed_scaffold/scripts/rename-placeholders.sh" "$tenant_name" >/dev/null

	secret_store=$renamed_scaffold/deploy/secretstore.yaml
	external_secret=$renamed_scaffold/deploy/externalsecret.yaml
	expected_remote_key=apps/$tenant_name/config
	export tenant_name expected_remote_key

	yq eval -e '
		.kind == "SecretStore"
		and .spec.provider.vault.auth.kubernetes.role == strenv(tenant_name)
		and .spec.provider.vault.auth.kubernetes.serviceAccountRef.name == strenv(tenant_name)
	' "$secret_store" >/dev/null ||
		fail "renamed scaffold no longer binds its OpenBao role to the tenant ServiceAccount"

	yq eval -e '
		.kind == "ExternalSecret"
		and (.spec.data | length) == 1
		and .spec.data[0].remoteRef.key == strenv(expected_remote_key)
	' "$external_secret" >/dev/null ||
		fail "renamed scaffold no longer reads the tenant-scoped OpenBao path"

	policy_header="bao policy write app-$tenant_name - <<'POLICY'"
	policy_count=$(grep -Fc -- "$policy_header" "$vault_config")
	[ "$policy_count" -eq 1 ] ||
		fail "Platform must declare the tenant OpenBao policy exactly once"
	policy_block=$(awk -v header="$policy_header" '
		index($0, header) { inside = 1; found = 1; next }
		inside && /^[[:space:]]*POLICY[[:space:]]*$/ { exit }
		inside { sub(/^[[:space:]]*/, ""); print }
		END { if (!found) exit 1 }
	' "$vault_config") || fail "Platform tenant OpenBao policy is missing"
	expected_policy_block=$(printf '%s\n' \
		"path \"secret/data/apps/$tenant_name/*\" {" \
		'capabilities = ["create", "update", "read"]' \
		'}' \
		"path \"secret/metadata/apps/$tenant_name/*\" {" \
		'capabilities = ["create", "update", "read"]' \
		'}')
	[ "$policy_block" = "$expected_policy_block" ] ||
		fail "Platform tenant OpenBao policy no longer has the exact data/metadata scope and capabilities"

	role_header="bao write auth/kubernetes/role/$tenant_name \\"
	role_count=$(grep -Fc -- "$role_header" "$vault_config")
	[ "$role_count" -eq 1 ] ||
		fail "Platform must declare the tenant OpenBao Kubernetes-auth role exactly once"
	role_block=$(awk -v header="$role_header" '
		index($0, header) { inside = 1; found = 1 }
		inside { sub(/^[[:space:]]*/, ""); print }
		inside && $0 == "ttl=1h" { exit }
		END { if (!found) exit 1 }
	' "$vault_config") || fail "Platform tenant OpenBao Kubernetes-auth role is missing"
	expected_role_block=$(printf '%s\n' \
		"bao write auth/kubernetes/role/$tenant_name \\" \
		"bound_service_account_names=$tenant_name \\" \
		"bound_service_account_namespaces=$tenant_name \\" \
		"policies=app-$tenant_name \\" \
		'ttl=1h')
	[ "$role_block" = "$expected_role_block" ] ||
		fail "Platform tenant OpenBao role no longer binds the exact policy, ServiceAccount, and namespace"
)


# Check the real Platform envelope, including every source consumer's safeguards.
validate_platform() {
	platform_root=$1
	scaffold_root=${2:-$repo_root}
	rgd=$platform_root/k8s/bases/infrastructure/resource-graph-definitions/tenant/resource-graph-definition.yaml
	vault_config=$platform_root/k8s/bases/infrastructure/vault-config/job.yaml
	manual_root=$platform_root/k8s/bases/apps/ascoachingogvaner
	manual_namespace=$manual_root/namespace.yaml
	manual_service_account=$manual_root/service-account.yaml
	manual_oci_repository=$manual_root/oci-repository.yaml
	manual_role_binding=$manual_root/role-binding-ascoachingogvaner.yaml
	manual_kustomization=$manual_root/flux-kustomization.yaml
	manual_inventory=$manual_root/kustomization.yaml

	for required_file in \
		"$rgd" \
		"$vault_config" \
		"$manual_namespace" \
		"$manual_service_account" \
		"$manual_oci_repository" \
		"$manual_role_binding" \
		"$manual_kustomization" \
		"$manual_inventory"
	do
		[ -f "$required_file" ] || fail "Platform tenant-envelope source is missing: $required_file"
	done

	yq eval-all -e '[.] | length == 1' "$rgd" >/dev/null ||
		fail "Platform KRO Tenant must contain exactly one YAML document"
	# shellcheck disable=SC2016
	yq eval -e '
		(.spec.resources[] | select(.id == "tenantNamespace").template) as $namespace
		| (.spec.resources[] | select(.id == "serviceAccount").template) as $serviceAccount
		| (.spec.resources[] | select(.id == "ociRepository").template) as $ociRepository
		| (.spec.resources[] | select(.id == "roleBinding").template) as $roleBinding
		| (.spec.resources[] | select(.id == "kustomization")) as $kustomizationResource
		| (.spec.resources[] | select(.id == "kustomizationSops")) as $kustomizationSopsResource
		| $kustomizationResource.template as $kustomization
		| $kustomizationSopsResource.template as $kustomizationSops
		| (([.spec.resources[] | select(.id == "ghcrAuth")] | length) == 0
		and ([.spec.resources[] | select(.id == "ociRepository")] | length) == 1
		and $namespace.kind == "Namespace"
		and $namespace.metadata.name == "${schema.spec.name}"
		and $namespace.metadata.labels."app.kubernetes.io/managed-by" == "kro"
		and $namespace.metadata.labels."pod-security.kubernetes.io/enforce" == "restricted"
		and $namespace.metadata.labels."pod-security.kubernetes.io/enforce-version" == "latest"
		and $serviceAccount.kind == "ServiceAccount"
		and $serviceAccount.metadata.name == "${schema.spec.name}"
		and $serviceAccount.metadata.namespace == "${tenantNamespace.metadata.name}"
		and $serviceAccount.metadata.labels."app.kubernetes.io/managed-by" == "kro"
		and $serviceAccount.automountServiceAccountToken == false
		and ($serviceAccount | has("imagePullSecrets") | not)
		and $ociRepository.kind == "OCIRepository"
		and $ociRepository.metadata.name == "${schema.spec.name}"
		and $ociRepository.metadata.namespace == "${tenantNamespace.metadata.name}"
		and ($ociRepository.spec.ref | '"$stable_stream"')
		and $ociRepository.spec.url == "oci://ghcr.io/devantler-tech/${schema.spec.name}/manifests"
		and ($ociRepository.spec | has("secretRef") | not)
		and ($ociRepository.spec | has("serviceAccountName") | not)
		and (($ociRepository.spec.suspend // false) == false)
		and $ociRepository.spec.verify.provider == "cosign"
		and ($ociRepository.spec.verify | has("secretRef") | not)
		and ($ociRepository.spec.verify.matchOIDCIdentity | length) == 1
		and $ociRepository.spec.verify.matchOIDCIdentity[0].issuer == strenv(expected_oidc_issuer)
		and ($ociRepository.spec.verify.matchOIDCIdentity[0].subject | tag == "!!str")
		and ($ociRepository.spec.verify.matchOIDCIdentity[0].subject | test("[[:cntrl:]]") | not)
		and $roleBinding.kind == "RoleBinding"
		and $roleBinding.metadata.name == "${schema.spec.name}"
		and $roleBinding.metadata.namespace == "${tenantNamespace.metadata.name}"
		and $roleBinding.roleRef.apiGroup == "rbac.authorization.k8s.io"
		and $roleBinding.roleRef.kind == "ClusterRole"
		and $roleBinding.roleRef.name == "tenant-edit"
		and ($roleBinding.subjects | length) == 1
		and $roleBinding.subjects[0].kind == "ServiceAccount"
		and $roleBinding.subjects[0].name == "${serviceAccount.metadata.name}"
		and $roleBinding.subjects[0].namespace == "${tenantNamespace.metadata.name}"
		and ($kustomizationResource.includeWhen | join("|")) == "${schema.spec.source.reconcileApplication && !schema.spec.sops}"
		and .spec.schema.types.TenantSource.reconcileApplication == "boolean | default=true validation=\"self || !oldSelf\""
		and $kustomization.kind == "Kustomization"
		and $kustomization.metadata.namespace == "${tenantNamespace.metadata.name}"
		and $kustomization.spec.serviceAccountName == "${serviceAccount.metadata.name}"
		and $kustomization.spec.sourceRef.kind == "OCIRepository"
		and $kustomization.spec.sourceRef.name == "${ociRepository.metadata.name}"
		and ($kustomization.spec.sourceRef | has("namespace") | not)
		and $kustomization.spec.targetNamespace == "${tenantNamespace.metadata.name}"
		and ($kustomizationSopsResource.includeWhen | join("|")) == "${schema.spec.source.reconcileApplication && schema.spec.sops}"
		and $kustomizationSops.kind == "Kustomization"
		and $kustomizationSops.metadata.namespace == "${tenantNamespace.metadata.name}"
		and $kustomizationSops.spec.serviceAccountName == "${serviceAccount.metadata.name}"
		and $kustomizationSops.spec.sourceRef.kind == "OCIRepository"
		and $kustomizationSops.spec.sourceRef.name == "${ociRepository.metadata.name}"
		and ($kustomizationSops.spec.sourceRef | has("namespace") | not)
		and $kustomizationSops.spec.targetNamespace == "${tenantNamespace.metadata.name}")
	' "$rgd" >/dev/null || fail "Platform KRO Tenant no longer provides the required namespace, RBAC, and Flux envelope"
	generic_subject=$(yq eval -r '.spec.resources[] | select(.id == "ociRepository").template.spec.verify.matchOIDCIdentity[0].subject' "$rgd")
	generic_subject=$(generic_own_release_subject "$generic_subject") ||
		fail "Platform KRO Tenant OCI subject is not the anchored own-release rule"
	[ -n "$publisher_identity" ] || fail "starter publisher must be validated before its Platform consumer"
	printf '%s\n' "$publisher_identity" | grep -Eq -- "$generic_subject" ||
		fail "Platform KRO Tenant does not accept the starter's exact pinned publisher"

	tenant_name=$(yq eval -r '.metadata.name // ""' "$manual_namespace")
	[ -n "$tenant_name" ] || fail "manual Platform tenant namespace has no name"
	expected_manual_oci_url=oci://ghcr.io/devantler-tech/$tenant_name/manifests
	export tenant_name expected_manual_oci_url
	validate_openbao_authorization "$platform_root" "$scaffold_root" "$tenant_name" || return 1

	# shellcheck disable=SC2016
	yq eval -e '
		.kind == "Namespace"
		and .metadata.name == strenv(tenant_name)
		and .metadata.labels."app.kubernetes.io/managed-by" == "ksail"
		and .metadata.labels."pod-security.kubernetes.io/enforce" == "restricted"
		and .metadata.labels."pod-security.kubernetes.io/enforce-version" == "latest"
	' "$manual_namespace" >/dev/null || fail "manual Platform tenant namespace lacks the managed restricted envelope"

	# shellcheck disable=SC2016
	yq eval -e '
		.kind == "ServiceAccount"
		and .metadata.name == strenv(tenant_name)
		and .metadata.namespace == strenv(tenant_name)
		and .metadata.labels."app.kubernetes.io/managed-by" == "ksail"
		and .automountServiceAccountToken == false
		and (has("imagePullSecrets") | not)
	' "$manual_service_account" >/dev/null || fail "manual Platform tenant ServiceAccount no longer matches its namespace"

	# shellcheck disable=SC2016
	yq eval -e '
		.kind == "OCIRepository"
		and .metadata.name == strenv(tenant_name)
		and .metadata.namespace == strenv(tenant_name)
		and (.spec.ref | '"$stable_stream"')
		and .spec.url == strenv(expected_manual_oci_url)
		and (.spec | has("secretRef") | not)
		and (.spec | has("serviceAccountName") | not)
		and ((.spec.suspend // false) == false)
		and .spec.verify.provider == "cosign"
		and (.spec.verify | has("secretRef") | not)
		and (.spec.verify.matchOIDCIdentity | length) == 1
		and .spec.verify.matchOIDCIdentity[0].issuer == strenv(expected_oidc_issuer)
		and (.spec.verify.matchOIDCIdentity[0].subject | tag == "!!str")
		and (.spec.verify.matchOIDCIdentity[0].subject | test("[[:space:][:cntrl:]]") | not)
	' "$manual_oci_repository" >/dev/null || fail "manual Platform tenant OCI source no longer requires the signed artifact"
	manual_subject=$(yq eval -r '.spec.verify.matchOIDCIdentity[0].subject' "$manual_oci_repository")
	# The manual source trusts only its own repository's release workflow, and
	# that repository is the tenant whose artifact path was bound above.
	[ "$manual_subject" = "$(own_release_subject "$tenant_name")" ] ||
		fail "manual Platform tenant OCI subject is not the anchored own-release rule for $tenant_name"

	# shellcheck disable=SC2016
	yq eval -e '
		.kind == "RoleBinding"
		and .metadata.name == strenv(tenant_name)
		and .metadata.namespace == strenv(tenant_name)
		and .roleRef.apiGroup == "rbac.authorization.k8s.io"
		and .roleRef.kind == "ClusterRole"
		and .roleRef.name == "tenant-edit"
		and (.subjects | length) == 1
		and .subjects[0].kind == "ServiceAccount"
		and .subjects[0].name == strenv(tenant_name)
		and .subjects[0].namespace == strenv(tenant_name)
	' "$manual_role_binding" >/dev/null || fail "manual Platform tenant RoleBinding no longer grants tenant-edit to its reconciler"

	# shellcheck disable=SC2016
	yq eval -e '
		.kind == "Kustomization"
		and .metadata.name == strenv(tenant_name)
		and .metadata.namespace == strenv(tenant_name)
		and .metadata.labels."app.kubernetes.io/managed-by" == "ksail"
		and .spec.serviceAccountName == strenv(tenant_name)
		and .spec.sourceRef.kind == "OCIRepository"
		and .spec.sourceRef.name == strenv(tenant_name)
		and (.spec.sourceRef | has("namespace") | not)
		and .spec.targetNamespace == strenv(tenant_name)
	' "$manual_kustomization" >/dev/null || fail "manual Platform tenant Flux Kustomization no longer impersonates and targets its namespace"

	yq eval -e '
		.kind == "Kustomization"
		and ([.resources[] | select(. == "namespace.yaml")] | length) == 1
		and ([.resources[] | select(. == "service-account.yaml")] | length) == 1
		and ([.resources[] | select(. == "external-secret.yaml")] | length) == 0
		and ([.resources[] | select(. == "oci-repository.yaml")] | length) == 1
		and ([.resources[] | select(. == "role-binding-ascoachingogvaner.yaml")] | length) == 1
		and ([.resources[] | select(. == "flux-kustomization.yaml")] | length) == 1
	' "$manual_inventory" >/dev/null || fail "manual Platform tenant inventory no longer applies every validated envelope resource"
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 2 ] || fail "usage: $0 --validate <platform-root>"
	validate_publish_workflow "$publish_workflow"
	validate_platform "$2"
	exit 0
fi

platform_root=${PLATFORM_ROOT:-$repo_root/.platform}
validate_publish_workflow "$publish_workflow"
validate_platform "$platform_root"

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT
baseline=$mutation_dir/baseline
mkdir -p \
	"$baseline/k8s/bases/infrastructure/resource-graph-definitions" \
	"$baseline/k8s/bases/infrastructure/vault-config" \
	"$baseline/k8s/bases/apps"
cp -R \
	"$platform_root/k8s/bases/infrastructure/resource-graph-definitions/tenant" \
	"$baseline/k8s/bases/infrastructure/resource-graph-definitions/tenant"
cp -R \
	"$platform_root/k8s/bases/apps/ascoachingogvaner" \
	"$baseline/k8s/bases/apps/ascoachingogvaner"
cp \
	"$platform_root/k8s/bases/infrastructure/vault-config/job.yaml" \
	"$baseline/k8s/bases/infrastructure/vault-config/job.yaml"

# Counted, not hand-written — so that adding a mutation cannot leave the PASS
# line overstating or understating coverage.
#
# Increment in every helper that REJECTS a mutant (fails when validation accepts
# it). That is five helpers, not the three obvious ones: run_vault_duplicate and
# run_scaffold_mutation do the same job under different names, and a count that
# skips them under-reports by five. run_vault_prefixed_role_control is
# deliberately excluded — it asserts the opposite direction (it fails when
# validation REJECTS), so it is a compatibility control, not a safety mutation.
#
# `+ 1` rather than ((n++)): under `set -e` the latter returns 1 on the increment
# from zero and would abort the suite on its very first mutation.
mutations_run=0

# Reject a mutated Platform envelope and count it as a safety control.
run_mutation() {
	mutations_run=$((mutations_run + 1))
	description=$1
	relative_file=$2
	mutation=$3
	mutant=$mutation_dir/mutant
	rm -rf "$mutant"
	cp -R "$baseline" "$mutant"
	yq eval "$mutation" "$mutant/$relative_file" > "$mutation_dir/mutant.yaml"
	mv "$mutation_dir/mutant.yaml" "$mutant/$relative_file"
	if (validate_platform "$mutant") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

# Reject a mutated publisher workflow without changing the baseline caller.
run_publish_mutation() {
	mutations_run=$((mutations_run + 1))
	description=$1
	mutation=$2
	mutant_workflow=$mutation_dir/cd-mutant.yaml
	yq eval "$mutation" "$publish_workflow" > "$mutant_workflow"
	if (validate_publish_workflow "$mutant_workflow") >/dev/null 2>&1; then
		fail "publish mutation passed: $description"
	fi
}

# Reject a changed OpenBao authorization stanza in a disposable Platform copy.
run_vault_mutation() {
	mutations_run=$((mutations_run + 1))
	description=$1
	mutation=$2
	mutant=$mutation_dir/vault-mutant
	rm -rf "$mutant"
	cp -R "$baseline" "$mutant"
	vault_mutant=$mutant/k8s/bases/infrastructure/vault-config/job.yaml
	sed "$mutation" "$vault_mutant" > "$mutation_dir/vault-mutant.yaml"
	mv "$mutation_dir/vault-mutant.yaml" "$vault_mutant"
	if (validate_platform "$mutant") >/dev/null 2>&1; then
		fail "OpenBao authorization mutation passed: $description"
	fi
}

# Reject duplicate OpenBao authorization stanzas copied between exact delimiters.
run_vault_duplicate() {
	mutations_run=$((mutations_run + 1))
	description=$1
	header=$2
	terminator=$3
	mutant=$mutation_dir/vault-duplicate
	rm -rf "$mutant"
	cp -R "$baseline" "$mutant"
	vault_mutant=$mutant/k8s/bases/infrastructure/vault-config/job.yaml
	awk -v header="$header" -v terminator="$terminator" '
		index($0, header) { capture = 1 }
		{ print }
		capture { duplicate = duplicate $0 ORS }
		capture && index($0, terminator) { capture = 0 }
		END { printf "%s", duplicate }
	' "$vault_mutant" > "$mutation_dir/vault-duplicate.yaml"
	mv "$mutation_dir/vault-duplicate.yaml" "$vault_mutant"
	if (validate_platform "$mutant") >/dev/null 2>&1; then
		fail "duplicate OpenBao authorization mutation passed: $description"
	fi
}

# Preserve acceptance of an unrelated role whose name shares the tenant prefix.
run_vault_prefixed_role_control() {
	description=$1
	mutant=$mutation_dir/vault-prefixed-role
	rm -rf "$mutant"
	cp -R "$baseline" "$mutant"
	vault_mutant=$mutant/k8s/bases/infrastructure/vault-config/job.yaml
	sed 's|auth/kubernetes/role/wedding-app|auth/kubernetes/role/ascoachingogvaner-legacy|' \
		"$vault_mutant" > "$mutation_dir/vault-prefixed-role.yaml"
	if cmp -s "$vault_mutant" "$mutation_dir/vault-prefixed-role.yaml"; then
		fail "OpenBao prefixed-role control did not mutate the baseline: $description"
	fi
	mv "$mutation_dir/vault-prefixed-role.yaml" "$vault_mutant"
	if ! (validate_platform "$mutant") >/dev/null 2>&1; then
		fail "OpenBao authorization compatibility control failed: $description"
	fi
}

# Reject a changed renamed-tenant manifest against the unchanged Platform source.
run_scaffold_mutation() {
	mutations_run=$((mutations_run + 1))
	description=$1
	relative_file=$2
	mutation=$3
	mutant=$mutation_dir/scaffold-mutant
	rm -rf "$mutant"
	mkdir -p "$mutant/scripts"
	cp -R "$repo_root/deploy" "$mutant/deploy"
	cp "$repo_root/scripts/rename-placeholders.sh" "$mutant/scripts/rename-placeholders.sh"
	yq eval "$mutation" "$mutant/$relative_file" > "$mutation_dir/scaffold-mutant.yaml"
	mv "$mutation_dir/scaffold-mutant.yaml" "$mutant/$relative_file"
	if (validate_platform "$platform_root" "$mutant") >/dev/null 2>&1; then
		fail "renamed scaffold authorization mutation passed: $description"
	fi
}


subject_controls_run=0
# Compare a manual tenant's literal signer subject with its expected verdict.
run_manual_subject_control() {
	description=$1
	control_subject=$2
	expected_result=$3
	control=$mutation_dir/subject-control
	rm -rf "$control"
	cp -R "$baseline" "$control"
	SUBJECT_CONTROL=$control_subject yq eval \
		'.spec.verify.matchOIDCIdentity[0].subject = strenv(SUBJECT_CONTROL)' \
		"$control/k8s/bases/apps/ascoachingogvaner/oci-repository.yaml" > "$mutation_dir/subject-control.yaml"
	mv "$mutation_dir/subject-control.yaml" "$control/k8s/bases/apps/ascoachingogvaner/oci-repository.yaml"
	result=reject
	if (validate_platform "$control") >/dev/null 2>&1; then
		result=accept
	fi
	[ "$result" = "$expected_result" ] || fail "manual subject control failed: $description ($result)"
	subject_controls_run=$((subject_controls_run + 1))
}

# The tenant's own release workflow on a release tag, written in its literal
# parts so each loosened variant changes exactly one of them. These exercise
# copies of the real Platform envelope, not examples searched for in the code.
control_prefix='^https://github\.com/devantler-tech/'
control_own_directory='/\.github/workflows/'
control_own_file='[^/]+\.ya?ml'
control_own_ref='@refs/tags/v'
control_own_semver='(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?'
control_own_tail=$control_own_directory$control_own_file$control_own_ref$control_own_semver
control_shared='\.github/\.github/workflows/publish-app\.yaml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
# Preserve the literal newline: command substitution would otherwise strip it.
control_newline='
'
run_manual_subject_control 'the tenant own release' \
	"${control_prefix}ascoachingogvaner${control_own_tail}\$" accept
run_manual_subject_control 'own release of another repository' \
	"${control_prefix}wedding-app${control_own_tail}\$" reject
run_manual_subject_control 'own release of a repository sharing the tenant prefix' \
	"${control_prefix}ascoachingogvaner-x${control_own_tail}\$" reject
run_manual_subject_control 'own release in any workflow path' \
	"${control_prefix}ascoachingogvaner${control_own_directory}.+\\.ya?ml${control_own_ref}${control_own_semver}\$" reject
run_manual_subject_control 'own release on a branch' \
	"${control_prefix}ascoachingogvaner${control_own_directory}${control_own_file}@refs/heads/${control_own_semver}\$" reject
run_manual_subject_control 'own release on any tag' \
	"${control_prefix}ascoachingogvaner${control_own_directory}${control_own_file}${control_own_ref}.+\$" reject
run_manual_subject_control 'own release in another organization' \
	"^https://github\\.com/evil-tech/ascoachingogvaner${control_own_tail}\$" reject
run_manual_subject_control 'missing start anchor' \
	"https://github\\.com/devantler-tech/ascoachingogvaner${control_own_tail}\$" reject
run_manual_subject_control 'missing end anchor' \
	"${control_prefix}ascoachingogvaner${control_own_tail}" reject
run_manual_subject_control 'suffix after the end anchor' \
	"${control_prefix}ascoachingogvaner${control_own_tail}\$junk" reject
run_manual_subject_control 'trailing newline after the end anchor' \
	"${control_prefix}ascoachingogvaner${control_own_tail}\$${control_newline}" reject
run_manual_subject_control 'own release beside the retired shared publisher' \
	"${control_prefix}(${control_shared}|ascoachingogvaner${control_own_tail})\$" reject
run_manual_subject_control 'retired shared publisher alone' \
	"${control_prefix}${control_shared}\$" reject

# Exercise the starter's producer identity and the KRO consumer together. A
# well-formed rule still fails if it does not accept the starter's identity.
producer_controls_run=0
rgd_path=k8s/bases/infrastructure/resource-graph-definitions/tenant/resource-graph-definition.yaml
manual_path=k8s/bases/apps/ascoachingogvaner
run_producer_control() {
	description=$1
	control_subject=$2
	expected_result=$3
	control=$mutation_dir/producer-control
	rm -rf "$control"
	cp -R "$baseline" "$control"
	SUBJECT_CONTROL=$control_subject yq eval \
		'(.spec.resources[] | select(.id == "ociRepository").template.spec.verify.matchOIDCIdentity[0].subject) = strenv(SUBJECT_CONTROL)' \
		"$control/$rgd_path" > "$mutation_dir/producer-control.yaml"
	mv "$mutation_dir/producer-control.yaml" "$control/$rgd_path"
	case "${4:-}" in
		platform-document) printf '\n---\n{}\n' >> "$control/$rgd_path" ;;
		null-subject|nul-subject)
			if [ "$4" = null-subject ]; then
				expression='(.spec.resources[] | select(.id == "ociRepository").template.spec.verify.matchOIDCIdentity[0].subject) = null'
			else
				expression='(.spec.resources[] | select(.id == "ociRepository").template.spec.verify.matchOIDCIdentity[0].subject) += "\u0000"'
			fi
			yq eval "$expression" "$control/$rgd_path" > "$mutation_dir/producer-control.yaml"
			mv "$mutation_dir/producer-control.yaml" "$control/$rgd_path"
			;;
		'') ;;
		*) fail "unknown producer-control mutation" ;;
	esac
	result=reject
	if (validate_platform "$control") >/dev/null 2>&1; then
		result=accept
	fi
	[ "$result" = "$expected_result" ] || fail "producer control failed: $description ($result)"
	producer_controls_run=$((producer_controls_run + 1))
}

# Literal CEL serialization of Platform's generic own-release rule: two string
# literals around the regex-escaped Tenant name. Each rejected variant changes one part.
# shellcheck disable=SC2016
control_name_expression=' + schema.spec.name.replace(".", "\\.").replace("-", "\\-") + '
# Encode one CEL string literal as JSON.
cel_literal() { printf '%s' "$1" | jq -Rs .; }
control_before=$(cel_literal "$control_prefix")
control_after=$(cel_literal "${control_own_tail}\$")
control_generic="\${${control_before}${control_name_expression}${control_after}}"
run_producer_control 'own-release rule accepts the starter' \
	"$control_generic" accept
run_producer_control 'loosened tenant tail' \
	"\${${control_before}${control_name_expression}$(cel_literal '.+$')}" reject
run_producer_control 'missing end anchor' \
	"\${${control_before}${control_name_expression}$(cel_literal "$control_own_tail")}" reject
run_producer_control 'branch instead of a release tag' \
	"\${${control_before}${control_name_expression}$(cel_literal "${control_own_directory}${control_own_file}@refs/heads/${control_own_semver}\$")}" reject
run_producer_control 'another organization' \
	"\${$(cel_literal '^https://github\.com/evil-tech/')${control_name_expression}${control_after}}" reject
run_producer_control 'missing start anchor' \
	"\${$(cel_literal 'https://github\.com/devantler-tech/')${control_name_expression}${control_after}}" reject
run_producer_control 'names the tenant namespace' \
	"\${${control_before} + schema.spec.namespace.replace(\".\", \"\\\\.\").replace(\"-\", \"\\\\-\") + ${control_after}}" reject
run_producer_control 'without the name escapes' \
	"\${${control_before} + schema.spec.name + ${control_after}}" reject
run_producer_control 'own release beside the retired shared publisher' \
	"\${$(cel_literal "${control_prefix}(${control_shared}|")${control_name_expression}$(cel_literal "${control_own_tail})\$")}" reject
run_producer_control 'retired conditional shared-publisher arm' \
	"\${schema.spec.source.publisherRevision == \"\" ? ${control_before}${control_name_expression}${control_after} : \"^https://github\\\\.com/devantler-tech/\\\\.github/\\\\.github/workflows/publish-app\\\\.yaml@\" + schema.spec.source.publisherRevision + \"\$\"}" reject
run_producer_control 'retired static shared publisher' \
	"${control_prefix}${control_shared}\$" reject
run_producer_control 'trailing newline in the rule' \
	"${control_generic}${control_newline}" reject
run_producer_control 'second KRO document' \
	"$control_generic" reject platform-document
run_producer_control 'null rule' \
	"$control_generic" reject null-subject
run_producer_control 'NUL in the rule' \
	"$control_generic" reject nul-subject

# Flux resolves a digest ahead of a semver range, so a digest silently freezes
# the stream; a floating tag or a widened range admits artifacts no stable
# release produced.
run_mutation "KRO OCI stream replaced by a floating tag" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ociRepository").template.spec.ref) = {"tag": "latest"}'
run_mutation "KRO OCI stream overridden by a digest" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ociRepository").template.spec.ref.digest) = "sha256:0000000000000000000000000000000000000000000000000000000000000000"'
run_mutation "KRO OCI stream widened to pre-releases" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ociRepository").template.spec.ref.semver) = ">=0.0.0-0"'
run_mutation "KRO OCI stream filter widened" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ociRepository").template.spec.ref.semverFilter) = ".*"'
run_mutation "application reconciliation defaults off" "$rgd_path" \
	'.spec.schema.types.TenantSource.reconcileApplication = "boolean | default=false"'
run_mutation "application reconciliation deletion guard removed" "$rgd_path" \
	'.spec.schema.types.TenantSource.reconcileApplication = "boolean | default=true"'
run_vault_mutation "tenant data path widened" \
	's|secret/data/apps/ascoachingogvaner/\*|secret/data/apps/*|'
run_vault_mutation "tenant metadata path crossed into another tenant" \
	's|secret/metadata/apps/ascoachingogvaner/\*|secret/metadata/apps/wedding-app/*|'
run_vault_mutation "tenant read capability removed" \
	'/bao policy write app-ascoachingogvaner/,/^[[:space:]]*POLICY$/s/"create", "update", "read"/"create", "update"/'
run_vault_mutation "tenant write capabilities removed" \
	'/bao policy write app-ascoachingogvaner/,/^[[:space:]]*POLICY$/s/"create", "update", "read"/"read"/'
run_vault_mutation "tenant role policy changed" \
	's/policies=app-ascoachingogvaner/policies=app-wedding-app/'
run_vault_mutation "tenant role ServiceAccount changed" \
	's/bound_service_account_names=ascoachingogvaner/bound_service_account_names=another-tenant/'
run_vault_mutation "tenant role namespace changed" \
	's/bound_service_account_namespaces=ascoachingogvaner/bound_service_account_namespaces=another-tenant/'
run_vault_mutation "tenant Kubernetes-auth role renamed" \
	's|auth/kubernetes/role/ascoachingogvaner|auth/kubernetes/role/another-tenant|'
run_vault_duplicate "tenant policy declared twice" \
	"bao policy write app-ascoachingogvaner - <<'POLICY'" 'POLICY'
run_vault_duplicate "tenant Kubernetes-auth role declared twice" \
	'bao write auth/kubernetes/role/ascoachingogvaner' 'ttl=1h'
run_vault_prefixed_role_control "another tenant role starts with this tenant name"
run_scaffold_mutation "scaffold OpenBao role changed" deploy/secretstore.yaml \
	'.spec.provider.vault.auth.kubernetes.role = "another-tenant"'
run_scaffold_mutation "scaffold OpenBao ServiceAccount changed" deploy/secretstore.yaml \
	'.spec.provider.vault.auth.kubernetes.serviceAccountRef.name = "another-tenant"'
run_scaffold_mutation "scaffold OpenBao path crossed into another tenant" deploy/externalsecret.yaml \
	'.spec.data[0].remoteRef.key = "apps/another-tenant/config"'
run_mutation "KRO managed-by label removed" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "tenantNamespace").template.metadata.labels."app.kubernetes.io/managed-by")'
run_mutation "KRO Pod Security level weakened" "$rgd_path" \
	'(.spec.resources[] | select(.id == "tenantNamespace").template.metadata.labels."pod-security.kubernetes.io/enforce") = "baseline"'
run_mutation "KRO tenant-edit binding changed" "$rgd_path" \
	'(.spec.resources[] | select(.id == "roleBinding").template.roleRef.name) = "edit"'
run_mutation "KRO non-SOPS reconciler identity removed" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "kustomization").template.spec.serviceAccountName)'
run_mutation "KRO non-SOPS target namespace removed" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "kustomization").template.spec.targetNamespace)'
run_mutation "KRO SOPS reconciler identity removed" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "kustomizationSops").template.spec.serviceAccountName)'
run_mutation "KRO SOPS target namespace removed" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "kustomizationSops").template.spec.targetNamespace)'
run_mutation "KRO reconciler kind changed" "$rgd_path" \
	'(.spec.resources[] | select(.id == "kustomization").template.kind) = "ConfigMap"'
# This is the literal KRO CEL expression written into the mutant.
# shellcheck disable=SC2016
run_mutation "KRO activation predicates overlap" "$rgd_path" \
	'(.spec.resources[] | select(.id == "kustomization").includeWhen) = ["${schema.spec.sops}"]'
run_mutation "KRO GHCR credential resource re-added" "$rgd_path" \
	'.spec.resources += [{"id": "ghcrAuth", "template": {"kind": "ExternalSecret"}}]'
run_mutation "KRO OCI source resource removed" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "ociRepository"))'
run_mutation "KRO image-pull credential re-attached" "$rgd_path" \
	'(.spec.resources[] | select(.id == "serviceAccount").template.imagePullSecrets) = [{"name": "ghcr-auth"}]'
run_mutation "KRO OCI tenant path widened" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ociRepository").template.spec.url) = "oci://ghcr.io/devantler-tech/manifests"'
run_mutation "KRO OCI pull credential re-attached" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ociRepository").template.spec.secretRef.name) = "ghcr-auth"'
run_mutation "KRO OCI pull identity attached" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ociRepository").template.spec.serviceAccountName) = "ghcr-puller"'
run_mutation "KRO OCI verification removed" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "ociRepository").template.spec.verify)'
run_mutation "KRO OCI issuer widened" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ociRepository").template.spec.verify.matchOIDCIdentity[0].issuer) = "^https://.*$"'
run_mutation "KRO OCI subject widened" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ociRepository").template.spec.verify.matchOIDCIdentity[0].subject) = "^https://github.com/devantler-tech/.*$"'
run_mutation "KRO OCI key verification override added" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ociRepository").template.spec.verify.secretRef.name) = "alternate-cosign-key"'
run_mutation "KRO OCI source suspended" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ociRepository").template.spec.suspend) = true'
run_mutation "KRO non-SOPS artifact source disconnected" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "kustomization").template.spec.sourceRef)'
run_mutation "KRO SOPS artifact source disconnected" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "kustomizationSops").template.spec.sourceRef)'
run_mutation "KRO non-SOPS artifact source crosses namespace" "$rgd_path" \
	'(.spec.resources[] | select(.id == "kustomization").template.spec.sourceRef.namespace) = "another-tenant"'
run_mutation "KRO SOPS artifact source crosses namespace" "$rgd_path" \
	'(.spec.resources[] | select(.id == "kustomizationSops").template.spec.sourceRef.namespace) = "another-tenant"'
run_mutation "manual managed-by label changed" "$manual_path/namespace.yaml" \
	'.metadata.labels."app.kubernetes.io/managed-by" = "manual"'
run_mutation "manual Pod Security level weakened" "$manual_path/namespace.yaml" \
	'.metadata.labels."pod-security.kubernetes.io/enforce" = "baseline"'
run_mutation "manual Namespace kind changed" "$manual_path/namespace.yaml" \
	'.kind = "ConfigMap"'
run_mutation "manual tenant-edit binding changed" "$manual_path/role-binding-ascoachingogvaner.yaml" \
	'.roleRef.name = "edit"'
run_mutation "manual reconciler identity removed" "$manual_path/flux-kustomization.yaml" \
	'del(.spec.serviceAccountName)'
run_mutation "manual target namespace removed" "$manual_path/flux-kustomization.yaml" \
	'del(.spec.targetNamespace)'
run_mutation "manual image-pull credential re-attached" "$manual_path/service-account.yaml" \
	'.imagePullSecrets = [{"name": "ghcr-auth"}]'
run_mutation "manual OCI tenant path changed" "$manual_path/oci-repository.yaml" \
	'(.spec.url) = "oci://ghcr.io/devantler-tech/another-tenant/manifests"'
run_mutation "manual OCI pull credential re-attached" "$manual_path/oci-repository.yaml" \
	'.spec.secretRef.name = "ghcr-auth"'
run_mutation "manual OCI pull identity attached" "$manual_path/oci-repository.yaml" \
	'.spec.serviceAccountName = "ghcr-puller"'
run_mutation "manual OCI verification removed" "$manual_path/oci-repository.yaml" \
	'del(.spec.verify)'
run_mutation "manual OCI subject widened" "$manual_path/oci-repository.yaml" \
	'(.spec.verify.matchOIDCIdentity[0].subject) = "^https://github.com/devantler-tech/.*$"'
run_mutation "manual OCI subject contains a NUL byte" "$manual_path/oci-repository.yaml" \
	'(.spec.verify.matchOIDCIdentity[0].subject) += "\u0000"'
run_mutation "manual OCI source suspended" "$manual_path/oci-repository.yaml" \
	'.spec.suspend = true'
# The release-stream selector keeps the tenant on its signed stable releases. Flux
# resolves a digest ahead of a semver range, so a digest silently freezes the
# stream; a floating tag or a widened range admits artifacts no stable release
# produced.
run_mutation "manual OCI stream widened to pre-releases" "$manual_path/oci-repository.yaml" \
	'(.spec.ref.semver) = ">=1.0.0-0"'
run_mutation "manual OCI stream widened to every version" "$manual_path/oci-repository.yaml" \
	'(.spec.ref.semver) = "*"'
run_mutation "manual OCI stream replaced by a floating tag" "$manual_path/oci-repository.yaml" \
	'.spec.ref = {"tag": "latest"}'
run_mutation "manual OCI stream overridden by a digest" "$manual_path/oci-repository.yaml" \
	'(.spec.ref.digest) = "sha256:0000000000000000000000000000000000000000000000000000000000000000"'
run_mutation "manual Flux artifact source disconnected" "$manual_path/flux-kustomization.yaml" \
	'del(.spec.sourceRef)'
run_mutation "manual Flux artifact source crosses namespace" "$manual_path/flux-kustomization.yaml" \
	'.spec.sourceRef.namespace = "another-tenant"'
run_mutation "manual Namespace removed from inventory" "$manual_path/kustomization.yaml" \
	'.resources -= ["namespace.yaml"]'
run_mutation "manual GHCR credential returned to inventory" "$manual_path/kustomization.yaml" \
	'.resources += ["external-secret.yaml"]'
run_mutation "manual OCI source removed from inventory" "$manual_path/kustomization.yaml" \
	'.resources -= ["oci-repository.yaml"]'

run_mutation "manual OCI stream filter widened" "$manual_path/oci-repository.yaml" \
	'(.spec.ref.semverFilter) = ".*"'

run_publish_mutation "tag trigger removed" 'del(.["on"].push.tags)'
run_publish_mutation "tenant-only guard removed" 'del(.jobs.publish.if)'
run_publish_mutation "package publication permission removed" 'del(.jobs.publish.permissions.packages)'
run_publish_mutation "OIDC signing permission removed" 'del(.jobs.publish.permissions."id-token")'
run_publish_mutation "producer action unpinned" \
	'.jobs.publish.steps[2].uses = "devantler-tech/.github/actions/publish-app@main"'
run_publish_mutation "producer action changed" \
	'.jobs.publish.steps[2].uses = "devantler-tech/.github/actions/other@47f0d9b632581a613963a2d25c243713f24c32a0"'
run_publish_mutation "application identity hard-coded" \
	'.jobs.publish.steps[2].with."app-name" = "app"'
run_publish_mutation "checkout keeps its credentials" \
	'.jobs.publish.steps[1].with."persist-credentials" = true'
run_publish_mutation "shared and own publisher combined" \
	'.jobs.publish.uses = "devantler-tech/.github/.github/workflows/publish-app.yaml@af042c540ce8db4d64add98c34b5c57691e0e812"'
run_publish_mutation "publisher authority widened" \
	'.jobs.publish.permissions.issues = "write"'
run_publish_mutation "branch publication enabled" \
	'.["on"].push.branches = ["main"]'
run_publish_mutation "second package publisher added" \
	'.jobs.shadow = {"runs-on": "ubuntu-latest", "permissions": {"packages": "write"}, "steps": []}'
run_publish_mutation "execution environment overridden" \
	'.env.PATH = "/untrusted"'

echo "PASS: signed tenant artifact envelope (KRO + manual + OpenBao + publisher + ${mutations_run} safety mutations + ${subject_controls_run} subject controls + ${producer_controls_run} producer controls)"
