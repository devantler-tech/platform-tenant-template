#!/usr/bin/env sh
# Verify that the template publishes a signed private artifact and Platform main
# still supplies the credential, verification, and Flux envelope that consumes it.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
publish_workflow=$repo_root/.github/workflows/cd.yaml
# Shape, not a specific revision: the producer identity and the requirement that
# it stay SHA-pinned are the contract; which SHA is Dependabot's business.
expected_publish_workflow='^devantler-tech/actions/\.github/workflows/publish-app\.yaml@[0-9a-f]{40}$'
# This is the literal GitHub Actions expression the reusable workflow consumes.
# shellcheck disable=SC2016
expected_publish_app_name='${{ github.event.repository.name }}'
expected_oidc_issuer='^https://token\.actions\.githubusercontent\.com$'
# Compared verbatim, not matched: this is the platform's declared trust rule, and
# asserting the exact text is the security property. It accepts only the shared
# actions workflow signed from a 40-hex commit SHA or a release tag, so a floating
# ref does not verify. Kept in step with platform's tenant ResourceGraphDefinition
# and its live OCIRepository rules, which all carry this identical string.
expected_oidc_subject='^https://github\.com/devantler-tech/actions/\.github/workflows/publish-app\.yaml@([0-9a-f]{40}|refs/tags/v.+)$'
export expected_publish_workflow expected_publish_app_name
export expected_oidc_issuer expected_oidc_subject

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

validate_publish_workflow() {
	workflow_file=$1
	[ -f "$workflow_file" ] || fail "tenant publish workflow is missing: $workflow_file"

	# The tag-only tenant job is the producer identity Platform's OCIRepository
	# accepts. Keep its authority both minimal and immutable.
	# shellcheck disable=SC2016
	yq eval -e '
		((.["on"] | length) == 1)
		and (.["on"] | has("push"))
		and ((.["on"].push | length) == 1)
		and ((.["on"].push.tags | length) == 1)
		and .["on"].push.tags[0] == "v*"
		and ((.permissions | length) == 0)
		and ((.jobs | length) == 1)
		and (.jobs | has("publish"))
		and .jobs.publish.if == "github.repository != '\''devantler-tech/gitops-tenant-template'\''"
		and ((.jobs.publish.permissions | length) == 3)
		and .jobs.publish.permissions.contents == "read"
		and .jobs.publish.permissions.packages == "write"
		and .jobs.publish.permissions."id-token" == "write"
		and (.jobs.publish.uses | test(strenv(expected_publish_workflow)))
		and .jobs.publish.with."app-name" == strenv(expected_publish_app_name)
	' "$workflow_file" >/dev/null ||
		fail "tenant publish workflow no longer has the pinned minimal signing contract"
}

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

validate_platform() {
	platform_root=$1
	scaffold_root=${2:-$repo_root}
	rgd=$platform_root/k8s/bases/infrastructure/resource-graph-definitions/tenant/resource-graph-definition.yaml
	vault_config=$platform_root/k8s/bases/infrastructure/vault-config/job.yaml
	manual_root=$platform_root/k8s/bases/apps/ascoachingogvaner
	manual_namespace=$manual_root/namespace.yaml
	manual_service_account=$manual_root/service-account.yaml
	manual_ghcr_auth=$manual_root/external-secret.yaml
	manual_oci_repository=$manual_root/oci-repository.yaml
	manual_role_binding=$manual_root/role-binding-ascoachingogvaner.yaml
	manual_kustomization=$manual_root/flux-kustomization.yaml
	manual_inventory=$manual_root/kustomization.yaml

	for required_file in \
		"$rgd" \
		"$vault_config" \
		"$manual_namespace" \
		"$manual_service_account" \
		"$manual_ghcr_auth" \
		"$manual_oci_repository" \
		"$manual_role_binding" \
		"$manual_kustomization" \
		"$manual_inventory"
	do
		[ -f "$required_file" ] || fail "Platform tenant-envelope source is missing: $required_file"
	done

	# shellcheck disable=SC2016
	yq eval -e '
		(.spec.resources[] | select(.id == "tenantNamespace").template) as $namespace
		| (.spec.resources[] | select(.id == "serviceAccount").template) as $serviceAccount
		| (.spec.resources[] | select(.id == "ghcrAuth").template) as $ghcrAuth
		| (.spec.resources[] | select(.id == "ociRepository").template) as $ociRepository
		| (.spec.resources[] | select(.id == "roleBinding").template) as $roleBinding
		| (.spec.resources[] | select(.id == "kustomization")) as $kustomizationResource
		| (.spec.resources[] | select(.id == "kustomizationSops")) as $kustomizationSopsResource
		| $kustomizationResource.template as $kustomization
		| $kustomizationSopsResource.template as $kustomizationSops
		| (([.spec.resources[] | select(.id == "ghcrAuth")] | length) == 1
		and ([.spec.resources[] | select(.id == "ociRepository")] | length) == 1
		and $namespace.kind == "Namespace"
		and $namespace.metadata.name == "${schema.spec.name}"
		and $namespace.metadata.labels."app.kubernetes.io/managed-by" == "ksail"
		and $namespace.metadata.labels."pod-security.kubernetes.io/enforce" == "restricted"
		and $namespace.metadata.labels."pod-security.kubernetes.io/enforce-version" == "latest"
		and $serviceAccount.kind == "ServiceAccount"
		and $serviceAccount.metadata.name == "${schema.spec.name}"
		and $serviceAccount.metadata.namespace == "${tenantNamespace.metadata.name}"
		and $serviceAccount.metadata.labels."app.kubernetes.io/managed-by" == "ksail"
		and $serviceAccount.automountServiceAccountToken == false
		and ($serviceAccount.imagePullSecrets | length) == 1
		and $serviceAccount.imagePullSecrets[0].name == "ghcr-auth"
		and $ghcrAuth.kind == "ExternalSecret"
		and $ghcrAuth.metadata.name == "ghcr-auth"
		and $ghcrAuth.metadata.namespace == "${tenantNamespace.metadata.name}"
		and $ghcrAuth.spec.secretStoreRef.name == "openbao"
		and $ghcrAuth.spec.secretStoreRef.kind == "ClusterSecretStore"
		and $ghcrAuth.spec.target.name == "ghcr-auth"
		and $ghcrAuth.spec.target.creationPolicy == "Owner"
		and $ghcrAuth.spec.target.template.type == "kubernetes.io/dockerconfigjson"
		and $ghcrAuth.spec.target.template.data.".dockerconfigjson" == "{{ .dockerconfigjson }}"
		and ($ghcrAuth.spec.data | length) == 1
		and $ghcrAuth.spec.data[0].secretKey == "dockerconfigjson"
		and $ghcrAuth.spec.data[0].remoteRef.key == "infrastructure/ghcr/auth"
		and $ghcrAuth.spec.data[0].remoteRef.property == "dockerconfigjson"
		and $ociRepository.kind == "OCIRepository"
		and $ociRepository.metadata.name == "${schema.spec.name}"
		and $ociRepository.metadata.namespace == "${tenantNamespace.metadata.name}"
		and $ociRepository.spec.ref.semver == ">=1.0.0"
		and $ociRepository.spec.url == "oci://ghcr.io/devantler-tech/${schema.spec.name}/manifests"
		and $ociRepository.spec.secretRef.name == "ghcr-auth"
		and (($ociRepository.spec.suspend // false) == false)
		and $ociRepository.spec.verify.provider == "cosign"
		and ($ociRepository.spec.verify | has("secretRef") | not)
		and ($ociRepository.spec.verify.matchOIDCIdentity | length) == 1
		and $ociRepository.spec.verify.matchOIDCIdentity[0].issuer == strenv(expected_oidc_issuer)
		and $ociRepository.spec.verify.matchOIDCIdentity[0].subject == strenv(expected_oidc_subject)
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
		and (($kustomizationResource.includeWhen | join("|")) == "${!schema.spec.sops}")
		and $kustomization.kind == "Kustomization"
		and $kustomization.metadata.namespace == "${tenantNamespace.metadata.name}"
		and $kustomization.spec.serviceAccountName == "${serviceAccount.metadata.name}"
		and $kustomization.spec.sourceRef.kind == "OCIRepository"
		and $kustomization.spec.sourceRef.name == "${ociRepository.metadata.name}"
		and ($kustomization.spec.sourceRef | has("namespace") | not)
		and $kustomization.spec.targetNamespace == "${tenantNamespace.metadata.name}"
		and (($kustomizationSopsResource.includeWhen | join("|")) == "${schema.spec.sops}")
		and $kustomizationSops.kind == "Kustomization"
		and $kustomizationSops.metadata.namespace == "${tenantNamespace.metadata.name}"
		and $kustomizationSops.spec.serviceAccountName == "${serviceAccount.metadata.name}"
		and $kustomizationSops.spec.sourceRef.kind == "OCIRepository"
		and $kustomizationSops.spec.sourceRef.name == "${ociRepository.metadata.name}"
		and ($kustomizationSops.spec.sourceRef | has("namespace") | not)
		and $kustomizationSops.spec.targetNamespace == "${tenantNamespace.metadata.name}")
	' "$rgd" >/dev/null || fail "Platform KRO Tenant no longer provides the required namespace, RBAC, and Flux envelope"

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
		and (.imagePullSecrets | length) == 1
		and .imagePullSecrets[0].name == "ghcr-auth"
	' "$manual_service_account" >/dev/null || fail "manual Platform tenant ServiceAccount no longer matches its namespace"

	# shellcheck disable=SC2016
	yq eval -e '
		.kind == "ExternalSecret"
		and .metadata.name == "ghcr-auth"
		and .metadata.namespace == strenv(tenant_name)
		and .spec.secretStoreRef.name == "openbao"
		and .spec.secretStoreRef.kind == "ClusterSecretStore"
		and .spec.target.name == "ghcr-auth"
		and .spec.target.creationPolicy == "Owner"
		and .spec.target.template.type == "kubernetes.io/dockerconfigjson"
		and .spec.target.template.data.".dockerconfigjson" == "{{ .dockerconfigjson }}"
		and (.spec.data | length) == 1
		and .spec.data[0].secretKey == "dockerconfigjson"
		and .spec.data[0].remoteRef.key == "infrastructure/ghcr/auth"
		and .spec.data[0].remoteRef.property == "dockerconfigjson"
	' "$manual_ghcr_auth" >/dev/null || fail "manual Platform tenant no longer produces the private GHCR pull secret"

	# shellcheck disable=SC2016
	yq eval -e '
		.kind == "OCIRepository"
		and .metadata.name == strenv(tenant_name)
		and .metadata.namespace == strenv(tenant_name)
		and .spec.ref.semver == ">=1.0.0"
		and .spec.url == strenv(expected_manual_oci_url)
		and .spec.secretRef.name == "ghcr-auth"
		and ((.spec.suspend // false) == false)
		and .spec.verify.provider == "cosign"
		and (.spec.verify | has("secretRef") | not)
		and (.spec.verify.matchOIDCIdentity | length) == 1
		and .spec.verify.matchOIDCIdentity[0].issuer == strenv(expected_oidc_issuer)
		and .spec.verify.matchOIDCIdentity[0].subject == strenv(expected_oidc_subject)
	' "$manual_oci_repository" >/dev/null || fail "manual Platform tenant OCI source no longer requires the signed private artifact"

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
		and ([.resources[] | select(. == "external-secret.yaml")] | length) == 1
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

run_mutation() {
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

run_publish_mutation() {
	description=$1
	mutation=$2
	mutant_workflow=$mutation_dir/cd-mutant.yaml
	yq eval "$mutation" "$publish_workflow" > "$mutant_workflow"
	if (validate_publish_workflow "$mutant_workflow") >/dev/null 2>&1; then
		fail "publish mutation passed: $description"
	fi
}

run_vault_mutation() {
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

run_vault_duplicate() {
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

run_vault_prefixed_role_control() {
	description=$1
	mutant=$mutation_dir/vault-prefixed-role
	rm -rf "$mutant"
	cp -R "$baseline" "$mutant"
	vault_mutant=$mutant/k8s/bases/infrastructure/vault-config/job.yaml
	sed 's|auth/kubernetes/role/wedding-app|auth/kubernetes/role/ascoachingogvaner-legacy|' \
		"$vault_mutant" > "$mutation_dir/vault-prefixed-role.yaml"
	mv "$mutation_dir/vault-prefixed-role.yaml" "$vault_mutant"
	if ! (validate_platform "$mutant") >/dev/null 2>&1; then
		fail "OpenBao authorization compatibility control failed: $description"
	fi
}

run_scaffold_mutation() {
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

rgd_path=k8s/bases/infrastructure/resource-graph-definitions/tenant/resource-graph-definition.yaml
manual_path=k8s/bases/apps/ascoachingogvaner
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
run_mutation "KRO GHCR credential resource removed" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "ghcrAuth"))'
run_mutation "KRO OCI source resource removed" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "ociRepository"))'
run_mutation "KRO image-pull credential disconnected" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "serviceAccount").template.imagePullSecrets)'
run_mutation "KRO GHCR source widened" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ghcrAuth").template.spec.data[0].remoteRef.key) = "apps/shared"'
run_mutation "KRO GHCR target type changed" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ghcrAuth").template.spec.target.template.type) = "Opaque"'
run_mutation "KRO GHCR docker config mapping removed" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "ghcrAuth").template.spec.target.template.data.".dockerconfigjson")'
run_mutation "KRO OCI tenant path widened" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ociRepository").template.spec.url) = "oci://ghcr.io/devantler-tech/manifests"'
run_mutation "KRO OCI pull credential disconnected" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "ociRepository").template.spec.secretRef)'
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
run_mutation "manual GHCR source property changed" "$manual_path/external-secret.yaml" \
	'(.spec.data[0].remoteRef.property) = "token"'
run_mutation "manual GHCR target type changed" "$manual_path/external-secret.yaml" \
	'(.spec.target.template.type) = "Opaque"'
run_mutation "manual GHCR docker config mapping removed" "$manual_path/external-secret.yaml" \
	'del(.spec.target.template.data.".dockerconfigjson")'
run_mutation "manual image-pull credential disconnected" "$manual_path/service-account.yaml" \
	'del(.imagePullSecrets)'
run_mutation "manual OCI tenant path changed" "$manual_path/oci-repository.yaml" \
	'(.spec.url) = "oci://ghcr.io/devantler-tech/another-tenant/manifests"'
run_mutation "manual OCI pull credential disconnected" "$manual_path/oci-repository.yaml" \
	'del(.spec.secretRef)'
run_mutation "manual OCI verification removed" "$manual_path/oci-repository.yaml" \
	'del(.spec.verify)'
run_mutation "manual OCI subject widened" "$manual_path/oci-repository.yaml" \
	'(.spec.verify.matchOIDCIdentity[0].subject) = "^https://github.com/devantler-tech/.*$"'
run_mutation "manual OCI key verification override added" "$manual_path/oci-repository.yaml" \
	'(.spec.verify.secretRef.name) = "alternate-cosign-key"'
run_mutation "manual OCI source suspended" "$manual_path/oci-repository.yaml" \
	'.spec.suspend = true'
run_mutation "manual Flux artifact source disconnected" "$manual_path/flux-kustomization.yaml" \
	'del(.spec.sourceRef)'
run_mutation "manual Flux artifact source crosses namespace" "$manual_path/flux-kustomization.yaml" \
	'.spec.sourceRef.namespace = "another-tenant"'
run_mutation "manual Namespace removed from inventory" "$manual_path/kustomization.yaml" \
	'.resources -= ["namespace.yaml"]'
run_mutation "manual GHCR credential removed from inventory" "$manual_path/kustomization.yaml" \
	'.resources -= ["external-secret.yaml"]'
run_mutation "manual OCI source removed from inventory" "$manual_path/kustomization.yaml" \
	'.resources -= ["oci-repository.yaml"]'

run_publish_mutation "tag trigger removed" 'del(.["on"].push.tags)'
run_publish_mutation "tenant-only guard removed" 'del(.jobs.publish.if)'
run_publish_mutation "package publication permission removed" 'del(.jobs.publish.permissions.packages)'
run_publish_mutation "OIDC signing permission removed" 'del(.jobs.publish.permissions."id-token")'
run_publish_mutation "producer workflow unpinned" \
	'.jobs.publish.uses = "devantler-tech/actions/.github/workflows/publish-app.yaml@main"'
run_publish_mutation "producer workflow changed" \
	'.jobs.publish.uses = "devantler-tech/actions/.github/workflows/other.yaml@47f0d9b632581a613963a2d25c243713f24c32a0"'
run_publish_mutation "application identity hard-coded" \
	'.jobs.publish.with."app-name" = "app"'
run_publish_mutation "publisher authority widened" \
	'.jobs.publish.permissions.issues = "write"'
run_publish_mutation "branch publication enabled" \
	'.["on"].push.branches = ["main"]'
run_publish_mutation "second package publisher added" \
	'.jobs.shadow = {"runs-on": "ubuntu-latest", "permissions": {"packages": "write"}, "steps": []}'

echo "PASS: signed tenant artifact envelope (KRO + manual + OpenBao + publisher + 70 safety mutations)"
