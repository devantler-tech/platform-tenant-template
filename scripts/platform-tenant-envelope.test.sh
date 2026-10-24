#!/usr/bin/env sh
# Verify that the template publishes a signed private artifact and Platform main
# still supplies the credential, verification, and Flux envelope that consumes it.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
publish_workflow=$repo_root/.github/workflows/cd.yaml
# Shape, not a specific revision: the producer identity and the requirement that
# it stay SHA-pinned are the contract; which SHA is Dependabot's business.
expected_publish_workflow='^devantler-tech/(actions|\.github)/\.github/workflows/publish-app\.yaml@[0-9a-f]{40}$'
# This is the literal GitHub Actions expression the reusable workflow consumes.
# shellcheck disable=SC2016
expected_publish_app_name='${{ github.event.repository.name }}'
expected_oidc_issuer='^https://token\.actions\.githubusercontent\.com$'
# The generic KRO rule may retain its existing legacy full-SHA pattern, but any
# maintained publisher must name one or two literal reviewed commits. The
# starter's complete pinned caller identity must match this rule.
publisher_identity=''
# A manually declared tenant's own OCIRepository is narrower: platform writes an
# explicit alternation of its approved publish-app.yaml revisions (full 40-hex SHAs)
# from scripts/publish-workflow-approved-revisions.tsv. Which SHAs is platform's
# business; that the subject names only full SHAs, and no wildcard, is the contract.
# The writer emits a legacy-only subject or a fully anchored pair of the legacy
# and maintained locations. Parse those literal forms below, rather than treating
# the subject itself as an executable regex or pinning one incidental text shape.
export expected_publish_workflow expected_publish_app_name
export expected_oidc_issuer

# Report the failed invariant and stop the envelope check with a nonzero status.
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# Require a bounded set of distinct, immutable, lowercase commit IDs.
validate_revision_group() (
	ref=$1
	maximum=$2
	minimum=1
	case "$ref" in
		'('*')') ref=${ref#\(}; ref=${ref%\)}; minimum=2 ;;
		*'|'*) exit 1 ;;
	esac
	# No regex metacharacters survive: only distinct, literal full commit IDs.
	printf '%s\n' "$ref" | awk -v minimum="$minimum" -v maximum="$maximum" '
		{
			count = split($0, revisions, "\\|")
			if (count < minimum || count > maximum) exit 1
			for (i = 1; i <= count; i++) {
				if (length(revisions[i]) != 40 || revisions[i] !~ /^[0-9a-f]+$/ || seen[revisions[i]]++) exit 1
			}
		}
		END { if (NR != 1) exit 1 }
	'
)

# Only a generic legacy rule may retain the existing full-commit wildcard.
validate_legacy_revision_group() (
	ref=$1
	scope=$2
	if [ "$scope" = generic ] && [ "$ref" = '[0-9a-f]{40}' ]; then
		exit 0
	fi
	validate_revision_group "$ref" 3
)

# Accept only the supported anchored app-publisher identities for this scope.
validate_oidc_subject() (
	subject=$1
	scope=$2
	case "$scope" in manual|generic) ;; *) exit 1 ;; esac
	prefix='^https://github\.com/devantler-tech/'
	legacy='actions/\.github/workflows/publish-app\.yaml@'
	canonical='\.github/\.github/workflows/publish-app\.yaml@'
	case "$subject" in
		"$prefix$legacy"*'$')
			ref=${subject#"$prefix$legacy"}
			ref=${ref%'$'}
			validate_legacy_revision_group "$ref" "$scope"
			;;
		"$prefix("*')$')
			pair=${subject#"$prefix("}
			pair=${pair%')$'}
			separator="|$canonical"
			case "$pair" in "$legacy"*"$separator"*) ;; *) exit 1 ;; esac
			refs=${pair#"$legacy"}
			legacy_ref=${refs%%"$separator"*}
			canonical_ref=${refs#*"$separator"}
			validate_legacy_revision_group "$legacy_ref" "$scope" && validate_revision_group "$canonical_ref" 2
			;;
		*) exit 1 ;;
	esac
)

# Select either arm of the supported publisher expression without executing CEL.
# The optional revision represents a TenantSource input in producer controls;
# authorization of a live tenant's caller remains the separate publisher-pin gate.
generic_default_subject() (
	subject=$1
	rgd=$2
	publisher_revision=${3:-}
	conditional_subject=0
	# shellcheck disable=SC2016
	prefix='${schema.spec.source.publisherRevision == "" ? '
	# shellcheck disable=SC2016
	suffix=' : "^https://github\\.com/devantler-tech/\\.github/\\.github/workflows/publish-app\\.yaml@" + schema.spec.source.publisherRevision + "$"}'
	case "$subject" in
		"$prefix"*"$suffix")
			conditional_subject=1
			# A full immutable revision is the only input the explicit arm may
			# interpolate. Approval is still the separate publisher-pin gate.
			yq eval -e '.spec.schema.types.TenantSource.publisherRevision == "string | default=\"\" maxLength=40 pattern=\"^$|^[0-9a-f]{40}$\""' "$rgd" >/dev/null || exit 1
			encoded=${subject#"$prefix"}
			encoded=${encoded%"$suffix"}
			# Decode the CEL string literal as JSON, without evaluating CEL or
			# treating its content as shell code. Check controls before the shell
			# can strip a trailing newline or NUL.
			subject=$(printf '%s' "$encoded" | jq -Rser 'fromjson | select(type == "string") | select(test("[[:space:][:cntrl:]]") | not)') || exit 1
			;;
	esac
	validate_oidc_subject "$subject" generic || exit 1
	if [ -n "$publisher_revision" ]; then
		[ "$conditional_subject" -eq 1 ] || exit 1
		validate_revision_group "$publisher_revision" 1 || exit 1
		subject='^https://github\.com/devantler-tech/\.github/\.github/workflows/publish-app\.yaml@'"$publisher_revision"'$'
	fi
	printf '%s\n' "$subject"
)

# Bind the tag-only publishing job to its immutable workflow and minimal authority.
validate_publish_workflow() {
	workflow_file=$1
	[ -f "$workflow_file" ] || fail "tenant publish workflow is missing: $workflow_file"
	yq eval-all -e '[.] | length == 1' "$workflow_file" >/dev/null ||
		fail "tenant publish workflow must contain exactly one YAML document"

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
		and .jobs.publish.if == "github.repository != '\''devantler-tech/platform-tenant-template'\''"
		and ((.jobs.publish.permissions | length) == 3)
		and .jobs.publish.permissions.contents == "read"
		and .jobs.publish.permissions.packages == "write"
		and .jobs.publish.permissions."id-token" == "write"
		and (.jobs.publish.uses | tag == "!!str")
		and (.jobs.publish.uses | test("[[:space:][:cntrl:]]") | not)
		and (.jobs.publish.uses | test(strenv(expected_publish_workflow)))
		and .jobs.publish.with."app-name" == strenv(expected_publish_app_name)
		and .jobs.publish.with."enable-caller-pin" == true
	' "$workflow_file" >/dev/null ||
		fail "tenant publish workflow no longer has the pinned minimal signing contract"
	publisher_identity="https://github.com/$(yq eval -r '.jobs.publish.uses' "$workflow_file")"
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

	yq eval-all -e '[.] | length == 1' "$rgd" >/dev/null ||
		fail "Platform KRO Tenant must contain exactly one YAML document"
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
		| (.spec.schema.types.TenantSource.digest == "string | default=\"\" maxLength=71 pattern=\"^$|^sha256:[0-9a-f]{64}$\""
			and .spec.schema.spec.source == "TenantSource | default={} validation=\"((!has(self.digest) || self.digest == '\'''\'') == (!has(self.publisherRevision) || self.publisherRevision == '\'''\'')) && (!has(self.reconcileApplication) || self.reconcileApplication || (has(self.digest) && self.digest != '\'''\''))\" validation=\"!has(oldSelf.digest) || oldSelf.digest == '\'''\'' || (has(self.digest) && self.digest != '\'''\'')\"") as $sourceSchemaValid
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
		and ((($ociRepository.spec.ref | tag) == "!!map"
				and ($ociRepository.spec.ref | length) == 1
				and $ociRepository.spec.ref.semver == ">=1.0.0")
			or ($ociRepository.spec.ref == "${schema.spec.source.digest == \"\" ? {\"semver\": \">=1.0.0\"} : {\"digest\": schema.spec.source.digest}}"
				and $sourceSchemaValid))
		and $ociRepository.spec.url == "oci://ghcr.io/devantler-tech/${schema.spec.name}/manifests"
		and $ociRepository.spec.secretRef.name == "ghcr-auth"
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
		and (($kustomizationResource.includeWhen | join("|")) == "${!schema.spec.sops}"
			or (($kustomizationResource.includeWhen | join("|")) == "${schema.spec.source.reconcileApplication && !schema.spec.sops}"
				and $sourceSchemaValid
				and .spec.schema.types.TenantSource.reconcileApplication == "boolean | default=true validation=\"self || !oldSelf\""))
		and $kustomization.kind == "Kustomization"
		and $kustomization.metadata.namespace == "${tenantNamespace.metadata.name}"
		and $kustomization.spec.serviceAccountName == "${serviceAccount.metadata.name}"
		and $kustomization.spec.sourceRef.kind == "OCIRepository"
		and $kustomization.spec.sourceRef.name == "${ociRepository.metadata.name}"
		and ($kustomization.spec.sourceRef | has("namespace") | not)
		and $kustomization.spec.targetNamespace == "${tenantNamespace.metadata.name}"
		and (($kustomizationSopsResource.includeWhen | join("|")) == "${schema.spec.sops}"
			or (($kustomizationSopsResource.includeWhen | join("|")) == "${schema.spec.source.reconcileApplication && schema.spec.sops}"
				and $sourceSchemaValid
				and .spec.schema.types.TenantSource.reconcileApplication == "boolean | default=true validation=\"self || !oldSelf\""))
		and $kustomizationSops.kind == "Kustomization"
		and $kustomizationSops.metadata.namespace == "${tenantNamespace.metadata.name}"
		and $kustomizationSops.spec.serviceAccountName == "${serviceAccount.metadata.name}"
		and $kustomizationSops.spec.sourceRef.kind == "OCIRepository"
		and $kustomizationSops.spec.sourceRef.name == "${ociRepository.metadata.name}"
		and ($kustomizationSops.spec.sourceRef | has("namespace") | not)
		and $kustomizationSops.spec.targetNamespace == "${tenantNamespace.metadata.name}")
	' "$rgd" >/dev/null || fail "Platform KRO Tenant no longer provides the required namespace, RBAC, and Flux envelope"
	generic_subject=$(yq eval -r '.spec.resources[] | select(.id == "ociRepository").template.spec.verify.matchOIDCIdentity[0].subject' "$rgd")
	generic_subject=$(generic_default_subject "$generic_subject" "$rgd" "${3:-}") ||
		fail "Platform KRO Tenant OCI subject is not an anchored app-publisher rule"
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
		and (.spec.ref | has("digest") | not)
		and (.spec.ref | has("tag") | not)
		and .spec.url == strenv(expected_manual_oci_url)
		and .spec.secretRef.name == "ghcr-auth"
		and ((.spec.suspend // false) == false)
		and .spec.verify.provider == "cosign"
		and (.spec.verify | has("secretRef") | not)
		and (.spec.verify.matchOIDCIdentity | length) == 1
		and .spec.verify.matchOIDCIdentity[0].issuer == strenv(expected_oidc_issuer)
		and (.spec.verify.matchOIDCIdentity[0].subject | tag == "!!str")
		and (.spec.verify.matchOIDCIdentity[0].subject | test("[[:space:][:cntrl:]]") | not)
	' "$manual_oci_repository" >/dev/null || fail "manual Platform tenant OCI source no longer requires the signed private artifact"
	manual_subject=$(yq eval -r '.spec.verify.matchOIDCIdentity[0].subject' "$manual_oci_repository")
	validate_oidc_subject "$manual_subject" manual ||
		fail "manual Platform tenant OCI subject is not an anchored, narrow app-publisher writer form"

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

# These are literal writer shapes, exercised against a copy of the real Platform
# envelope, not examples merely searched for in the implementation. Platform owns
# the approved revisions; this check holds its serialization to narrow app-only
# identities. Nothing here grants a new revision or changes the starter's caller.
control_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
control_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
control_c=cccccccccccccccccccccccccccccccccccccccc
control_d=dddddddddddddddddddddddddddddddddddddddd
control_prefix='^https://github\.com/devantler-tech/'
control_legacy='actions/\.github/workflows/publish-app\.yaml@'
control_canonical='\.github/\.github/workflows/publish-app\.yaml@'
run_manual_subject_control 'one legacy revision' \
	"${control_prefix}${control_legacy}${control_a}\$" accept
run_manual_subject_control 'two legacy revisions' \
	"${control_prefix}${control_legacy}(${control_a}|${control_b})\$" accept
run_manual_subject_control 'three legacy revisions' \
	"${control_prefix}${control_legacy}(${control_a}|${control_b}|${control_c})\$" accept
run_manual_subject_control 'both locations with one revision each' \
	"${control_prefix}(${control_legacy}${control_a}|${control_canonical}${control_b})\$" accept
run_manual_subject_control 'one legacy and two maintained revisions' \
	"${control_prefix}(${control_legacy}${control_a}|${control_canonical}(${control_c}|${control_d}))\$" accept
run_manual_subject_control 'two legacy and two maintained revisions' \
	"${control_prefix}(${control_legacy}(${control_a}|${control_b})|${control_canonical}(${control_c}|${control_d}))\$" accept
run_manual_subject_control 'three legacy and two maintained revisions' \
	"${control_prefix}(${control_legacy}(${control_a}|${control_b}|${control_c})|${control_canonical}(${control_c}|${control_d}))\$" accept
run_manual_subject_control 'three legacy and one maintained revision' \
	"${control_prefix}(${control_legacy}(${control_a}|${control_b}|${control_c})|${control_canonical}${control_d})\$" accept
run_manual_subject_control 'two legacy and one maintained revision' \
	"${control_prefix}(${control_legacy}(${control_a}|${control_b})|${control_canonical}${control_c})\$" accept
run_manual_subject_control 'same SHA remains distinct across locations' \
	"${control_prefix}(${control_legacy}${control_a}|${control_canonical}${control_a})\$" accept
run_manual_subject_control 'maintained tag' \
	"${control_prefix}(${control_legacy}${control_a}|${control_canonical}v7.23.0)\$" reject
run_manual_subject_control 'maintained branch' \
	"${control_prefix}(${control_legacy}${control_a}|${control_canonical}main)\$" reject
run_manual_subject_control 'maintained short SHA' \
	"${control_prefix}(${control_legacy}${control_a}|${control_canonical}ccccccc)\$" reject
run_manual_subject_control 'maintained wildcard' \
	"${control_prefix}(${control_legacy}${control_a}|${control_canonical}.*)\$" reject
run_manual_subject_control 'third maintained revision' \
	"${control_prefix}(${control_legacy}${control_a}|${control_canonical}(${control_b}|${control_c}|${control_d}))\$" reject
run_manual_subject_control 'duplicate maintained revision' \
	"${control_prefix}(${control_legacy}${control_a}|${control_canonical}(${control_b}|${control_b}))\$" reject
run_manual_subject_control 'duplicate legacy revision' \
	"${control_prefix}${control_legacy}(${control_a}|${control_a})\$" reject
run_manual_subject_control 'four legacy revisions' \
	"${control_prefix}${control_legacy}(${control_a}|${control_b}|${control_c}|${control_d})\$" reject
run_manual_subject_control 'ungrouped locations' \
	"${control_prefix}${control_legacy}${control_a}|${control_canonical}${control_b}\$" reject
run_manual_subject_control 'different maintained workflow' \
	"${control_prefix}(${control_legacy}${control_a}|\\.github/\\.github/workflows/publish-manifests\\.yaml@${control_b})\$" reject
run_manual_subject_control 'different maintained repository' \
	"${control_prefix}(${control_legacy}${control_a}|other/\\.github/workflows/publish-app\\.yaml@${control_b})\$" reject
run_manual_subject_control 'unescaped maintained repository dots' \
	"${control_prefix}(${control_legacy}${control_a}|.github/\\.github/workflows/publish-app\\.yaml@${control_b})\$" reject
run_manual_subject_control 'missing pair end anchor' \
	"${control_prefix}(${control_legacy}${control_a}|${control_canonical}${control_b})" reject
run_manual_subject_control 'suffix after pair end anchor' \
	"${control_prefix}(${control_legacy}${control_a}|${control_canonical}${control_b})\$junk" reject
# Preserve the literal newline: command substitution would otherwise strip it.
control_newline='
'
run_manual_subject_control 'trailing newline after pair end anchor' \
	"${control_prefix}(${control_legacy}${control_a}|${control_canonical}${control_b})\$${control_newline}" reject
run_manual_subject_control 'canonical-only form not emitted by writer' \
	"${control_prefix}${control_canonical}${control_b}\$" reject

# Exercise the actual caller and KRO consumer together. A well-formed signer
# expression still fails if it does not accept the caller's full identity.
producer_controls_run=0
# Exercise producer identity and envelope compatibility together on real copies.
# Argument six supplies the conditional TenantSource publisherRevision input.
run_producer_control() {
	description=$1
	control_subject=$2
	control_caller=$3
	expected_result=$4
	control=$mutation_dir/producer-control
	rm -rf "$control"
	cp -R "$baseline" "$control"
	SUBJECT_CONTROL=$control_subject yq eval \
		'(.spec.resources[] | select(.id == "ociRepository").template.spec.verify.matchOIDCIdentity[0].subject) = strenv(SUBJECT_CONTROL)' \
		"$control/k8s/bases/infrastructure/resource-graph-definitions/tenant/resource-graph-definition.yaml" > "$mutation_dir/producer-control.yaml"
	mv "$mutation_dir/producer-control.yaml" "$control/k8s/bases/infrastructure/resource-graph-definitions/tenant/resource-graph-definition.yaml"
	CALLER_CONTROL=$control_caller yq eval '.jobs.publish.uses = strenv(CALLER_CONTROL)' \
		"$publish_workflow" > "$mutation_dir/producer-cd.yaml"
	case "${5:-}" in
		static-ref)
			yq eval '(.spec.resources[] | select(.id == "ociRepository").template.spec.ref) = {"semver": ">=1.0.0"}' \
				"$control/k8s/bases/infrastructure/resource-graph-definitions/tenant/resource-graph-definition.yaml" > "$mutation_dir/producer-control.yaml"
			mv "$mutation_dir/producer-control.yaml" "$control/k8s/bases/infrastructure/resource-graph-definitions/tenant/resource-graph-definition.yaml"
			;;
		workflow-document) printf '\n---\n{}\n' >> "$mutation_dir/producer-cd.yaml" ;;
		platform-document) printf '\n---\n{}\n' >> "$control/k8s/bases/infrastructure/resource-graph-definitions/tenant/resource-graph-definition.yaml" ;;
		null-subject|nul-subject)
			if [ "$5" = null-subject ]; then
				expression='(.spec.resources[] | select(.id == "ociRepository").template.spec.verify.matchOIDCIdentity[0].subject) = null'
			else
				expression='(.spec.resources[] | select(.id == "ociRepository").template.spec.verify.matchOIDCIdentity[0].subject) += "\u0000"'
			fi
			yq eval "$expression" "$control/k8s/bases/infrastructure/resource-graph-definitions/tenant/resource-graph-definition.yaml" > "$mutation_dir/producer-control.yaml"
			mv "$mutation_dir/producer-control.yaml" "$control/k8s/bases/infrastructure/resource-graph-definitions/tenant/resource-graph-definition.yaml"
			;;
		null-caller|nul-caller)
			if [ "$5" = null-caller ]; then
				expression='.jobs.publish.uses = null'
			else
				expression='.jobs.publish.uses += "\u0000"'
			fi
			yq eval "$expression" "$mutation_dir/producer-cd.yaml" > "$mutation_dir/producer-cd-mutant.yaml"
			mv "$mutation_dir/producer-cd-mutant.yaml" "$mutation_dir/producer-cd.yaml"
			;;
		'') ;;
		*) fail "unknown producer-control mutation" ;;
	esac
	result=reject
	if (validate_publish_workflow "$mutation_dir/producer-cd.yaml"; validate_platform "$control" "$repo_root" "${6:-}") >/dev/null 2>&1; then
		result=accept
	fi
	[ "$result" = "$expected_result" ] || fail "producer control failed: $description ($result)"
	producer_controls_run=$((producer_controls_run + 1))
}

control_legacy_caller=devantler-tech/actions/.github/workflows/publish-app.yaml@$control_a
control_maintained_caller=devantler-tech/.github/.github/workflows/publish-app.yaml@$control_b
control_generic_legacy="${control_prefix}${control_legacy}[0-9a-f]{40}\$"
control_generic_transition="${control_prefix}(${control_legacy}[0-9a-f]{40}|${control_canonical}${control_b})\$"
run_producer_control 'static OCI ref retains conditional reconciliation safeguards' \
	"$control_generic_transition" "$control_maintained_caller" accept static-ref
# Literal CEL serialization from Platform's TenantSource publisher contract.
# Exercise both arms; an explicit revision must remain a single full revision,
# never an executable or widened publisher expression.
# shellcheck disable=SC2016
control_conditional_prefix='${schema.spec.source.publisherRevision == "" ? '
# shellcheck disable=SC2016
control_conditional_suffix=' : "^https://github\\.com/devantler-tech/\\.github/\\.github/workflows/publish-app\\.yaml@" + schema.spec.source.publisherRevision + "$"}'
control_conditional_default=$(printf '%s' "$control_generic_transition" | jq -Rs .)
control_conditional_subject=$control_conditional_prefix$control_conditional_default$control_conditional_suffix
run_producer_control 'conditional default accepts its approved maintained caller' \
	"$control_conditional_subject" "$control_maintained_caller" accept
run_producer_control 'conditional default rejects an unapproved maintained revision' \
	"$control_conditional_subject" "devantler-tech/.github/.github/workflows/publish-app.yaml@$control_d" reject
run_producer_control 'conditional default retains the pinned legacy caller' \
	"$control_conditional_subject" "$control_legacy_caller" accept
run_producer_control 'conditional explicit revision accepts the matching maintained caller' \
	"$control_conditional_subject" "$control_maintained_caller" accept '' "$control_b"
run_producer_control 'conditional explicit revision selects its caller instead of the default' \
	"$control_conditional_subject" "devantler-tech/.github/.github/workflows/publish-app.yaml@$control_c" accept '' "$control_c"
run_producer_control 'conditional explicit revision rejects a different maintained caller' \
	"$control_conditional_subject" "$control_maintained_caller" reject '' "$control_d"
run_producer_control 'conditional explicit revision cannot authorize the legacy caller' \
	"$control_conditional_subject" "$control_legacy_caller" reject '' "$control_a"
run_producer_control 'conditional explicit revision rejects a wildcard' \
	"$control_conditional_subject" "$control_maintained_caller" reject '' '.*'
run_producer_control 'conditional explicit revision rejects a short commit ID' \
	"$control_conditional_subject" "$control_maintained_caller" reject '' 'bbbbbbb'
run_producer_control 'conditional explicit revision rejects uppercase commit IDs' \
	"$control_conditional_subject" "$control_maintained_caller" reject '' 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
run_producer_control 'static publisher subject cannot consume an explicit revision' \
	"$control_generic_transition" "$control_maintained_caller" reject '' "$control_b"
run_producer_control 'conditional explicit branch cannot widen the publisher' \
	"$control_conditional_prefix$control_conditional_default : \".*\"}" "$control_maintained_caller" reject
run_producer_control 'conditional expression cannot execute a different operation' \
	"\${other.operation() ? $control_conditional_default$control_conditional_suffix" "$control_maintained_caller" reject
run_producer_control 'current generic legacy rule accepts a pinned legacy caller' \
	"$control_generic_legacy" "$control_legacy_caller" accept
run_producer_control 'transition retains the pinned legacy caller' \
	"$control_generic_transition" "$control_legacy_caller" accept
run_producer_control 'transition accepts its exact maintained caller' \
	"$control_generic_transition" "$control_maintained_caller" accept
run_producer_control 'two exact maintained revisions' \
	"${control_prefix}(${control_legacy}[0-9a-f]{40}|${control_canonical}(${control_b}|${control_c}))\$" \
	"$control_maintained_caller" accept
run_producer_control 'fully literal transition' \
	"${control_prefix}(${control_legacy}${control_a}|${control_canonical}${control_b})\$" \
	"$control_maintained_caller" accept
run_producer_control 'maintained caller without maintained authorization' \
	"$control_generic_legacy" "$control_maintained_caller" reject
run_producer_control 'maintained caller at an unapproved revision' \
	"$control_generic_transition" "devantler-tech/.github/.github/workflows/publish-app.yaml@$control_d" reject
run_producer_control 'legacy caller at an unapproved literal revision' \
	"${control_prefix}${control_legacy}${control_c}\$" "$control_legacy_caller" reject
run_producer_control 'maintained wildcard' \
	"${control_prefix}(${control_legacy}[0-9a-f]{40}|${control_canonical}[0-9a-f]{40})\$" \
	"$control_maintained_caller" reject
run_producer_control 'maintained tag' \
	"${control_prefix}(${control_legacy}[0-9a-f]{40}|${control_canonical}v7.23.0)\$" \
	"$control_maintained_caller" reject
run_producer_control 'third maintained revision' \
	"${control_prefix}(${control_legacy}[0-9a-f]{40}|${control_canonical}(${control_b}|${control_c}|${control_d}))\$" \
	"$control_maintained_caller" reject
run_producer_control 'duplicate maintained revision' \
	"${control_prefix}(${control_legacy}[0-9a-f]{40}|${control_canonical}(${control_b}|${control_b}))\$" \
	"$control_maintained_caller" reject
run_producer_control 'legacy short identifier pattern' \
	"${control_prefix}(${control_legacy}[0-9a-f]{7,40}|${control_canonical}${control_b})\$" \
	"$control_maintained_caller" reject
run_producer_control 'different maintained workflow' \
	"${control_prefix}(${control_legacy}[0-9a-f]{40}|\\.github/\\.github/workflows/publish-manifests\\.yaml@${control_b})\$" \
	"$control_maintained_caller" reject
run_producer_control 'ungrouped producer locations' \
	"${control_prefix}${control_legacy}[0-9a-f]{40}|${control_canonical}${control_b}\$" \
	"$control_maintained_caller" reject
run_producer_control 'trailing newline in generic subject' \
	"${control_generic_transition}${control_newline}" "$control_maintained_caller" reject
run_producer_control 'lookalike caller repository' \
	"$control_generic_transition" "devantler-tech/another/.github/workflows/publish-app.yaml@$control_b" reject
run_producer_control 'mutable maintained caller' \
	"$control_generic_transition" 'devantler-tech/.github/.github/workflows/publish-app.yaml@main' reject
run_producer_control 'caller contains a trailing newline' \
	"$control_generic_transition" "${control_maintained_caller}${control_newline}" reject
run_producer_control 'second workflow document' \
	"$control_generic_transition" "$control_maintained_caller" reject workflow-document
run_producer_control 'second KRO document' \
	"$control_generic_transition" "$control_maintained_caller" reject platform-document
run_producer_control 'null generic subject' \
	"$control_generic_transition" "$control_maintained_caller" reject null-subject
run_producer_control 'NUL in generic subject' \
	"$control_generic_transition" "$control_maintained_caller" reject nul-subject
run_producer_control 'null publisher caller' \
	"$control_generic_transition" "$control_maintained_caller" reject null-caller
run_producer_control 'NUL in publisher caller' \
	"$control_generic_transition" "$control_maintained_caller" reject nul-caller

rgd_path=k8s/bases/infrastructure/resource-graph-definitions/tenant/resource-graph-definition.yaml
manual_path=k8s/bases/apps/ascoachingogvaner
run_mutation "conditional publisher revision schema becomes mutable" "$rgd_path" \
	'.spec.schema.types.TenantSource.publisherRevision = "string"'
run_mutation "conditional digest schema becomes mutable" "$rgd_path" \
	'.spec.schema.types.TenantSource.digest = "string"'
run_mutation "conditional source loses digest and publisher pairing" "$rgd_path" \
	'.spec.schema.spec.source = "TenantSource | default={}"'
run_mutation "static OCI ref bypasses conditional source safeguards" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ociRepository").template.spec.ref) = {"semver": ">=1.0.0"} | .spec.schema.spec.source = "TenantSource | default={}"'
run_mutation "static OCI ref bypasses conditional digest validation" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ociRepository").template.spec.ref) = {"semver": ">=1.0.0"} | .spec.schema.types.TenantSource.digest = "string"'
run_mutation "application reconciliation defaults off" "$rgd_path" \
	'.spec.schema.types.TenantSource.reconcileApplication = "boolean | default=false"'
# This is a literal CEL expression in the mutated source, not shell expansion.
# shellcheck disable=SC2016
run_mutation "conditional source accepts a mutable ref" "$rgd_path" \
	'(.spec.resources[] | select(.id == "ociRepository").template.spec.ref) = "${schema.spec.source.digest == \"\" ? {\"semver\": \">=1.0.0\"} : {\"tag\": schema.spec.source.digest}}"'
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
run_mutation "manual OCI subject contains a NUL byte" "$manual_path/oci-repository.yaml" \
	'(.spec.verify.matchOIDCIdentity[0].subject) = "^https://github\\.com/devantler-tech/actions/\\.github/workflows/publish-app\\.yaml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa$\u0000"'
run_mutation "manual OCI key verification override added" "$manual_path/oci-repository.yaml" \
	'(.spec.verify.secretRef.name) = "alternate-cosign-key"'
# The narrow subject parser must reject mutable refs and foreign producers.
run_mutation "manual OCI subject ref floated to a tag" "$manual_path/oci-repository.yaml" \
	'(.spec.verify.matchOIDCIdentity[0].subject) = "^https://github\.com/devantler-tech/actions/\.github/workflows/publish-app\.yaml@v1\.2\.3$"'
run_mutation "manual OCI subject ref floated to a branch" "$manual_path/oci-repository.yaml" \
	'(.spec.verify.matchOIDCIdentity[0].subject) = "^https://github\.com/devantler-tech/actions/\.github/workflows/publish-app\.yaml@main$"'
run_mutation "manual OCI subject ref accepts short SHAs" "$manual_path/oci-repository.yaml" \
	'(.spec.verify.matchOIDCIdentity[0].subject) = "^https://github\.com/devantler-tech/actions/\.github/workflows/publish-app\.yaml@[0-9a-f]{7,40}$"'
run_mutation "manual OCI subject end anchor dropped" "$manual_path/oci-repository.yaml" \
	'(.spec.verify.matchOIDCIdentity[0].subject) = "^https://github\.com/devantler-tech/actions/\.github/workflows/publish-app\.yaml@[0-9a-f]{40}"'
run_mutation "manual OCI subject alternation left ungrouped" "$manual_path/oci-repository.yaml" \
	'(.spec.verify.matchOIDCIdentity[0].subject) = "^https://github\.com/devantler-tech/actions/\.github/workflows/publish-app\.yaml@1d726483facb9340655489913f609082677be8f5|b089a1b0b089a1b0b089a1b0b089a1b0b089a1b0$"'
run_mutation "manual OCI subject groups a single revision" "$manual_path/oci-repository.yaml" \
	'(.spec.verify.matchOIDCIdentity[0].subject) = "^https://github\.com/devantler-tech/actions/\.github/workflows/publish-app\.yaml@(1d726483facb9340655489913f609082677be8f5)$"'
run_mutation "manual OCI subject group holds a wildcard" "$manual_path/oci-repository.yaml" \
	'(.spec.verify.matchOIDCIdentity[0].subject) = "^https://github\.com/devantler-tech/actions/\.github/workflows/publish-app\.yaml@(1d726483facb9340655489913f609082677be8f5|.*)$"'
run_mutation "manual OCI subject producer org changed" "$manual_path/oci-repository.yaml" \
	'(.spec.verify.matchOIDCIdentity[0].subject) = "^https://github\.com/evil-tech/actions/\.github/workflows/publish-app\.yaml@[0-9a-f]{40}$"'
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
# Both halves are load-bearing, and neither implies the other: a weaker assertion
# written as has("enable-caller-pin") would still reject the deletion while
# happily accepting an explicit false — which is the mutation that silently
# restores the unenforced default. Deleting the pair is what would let the
# caller-pin requirement decay back to opt-in without a failing test.
run_publish_mutation "caller SHA-pin enforcement removed" \
	'del(.jobs.publish.with."enable-caller-pin")'
run_publish_mutation "caller SHA-pin enforcement disabled" \
	'.jobs.publish.with."enable-caller-pin" = false'

echo "PASS: signed tenant artifact envelope (KRO + manual + OpenBao + publisher + ${mutations_run} safety mutations + ${subject_controls_run} subject controls + ${producer_controls_run} producer controls)"
