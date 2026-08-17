#!/usr/bin/env sh
# rename-placeholders.test.sh — exercise scripts/rename-placeholders.sh end-to-end.
#
# rename-placeholders.sh is the first thing a newcomer runs after `Use this
# template` — it rewrites the `app`, REPLACE_ME, and `replace-me` placeholders
# across deploy/*.yaml into the tenant's real name. A silent regression ships
# broken manifests to every tenant created from this scaffold, and it had no
# other coverage. The existing validation gate schema-validates the *unrenamed*
# manifests but never runs the rename, so a botched sed address would pass green.
# This test pins the script's real, subtle behaviour:
#   * REPLACE_ME values (the image and the OpenBao KV path) are repointed,
#   * every `app`-as-a-VALUE is renamed (resource names, label values, hostnames,
#     Homepage discovery identity, and the CNPG database/owner), while the
#     `app.kubernetes.io/name` label *KEY* is left intact (only its value changes),
#   * CloudNativePG's literal `-app` Secret suffix is preserved (`app-db-app`
#     becomes `<name>-db-app`, NOT `<name>-db-<name>`),
#   * the shared `openbao` SecretStore name is NOT renamed,
#   * the lowercase `replace-me` Vault role / ServiceAccount placeholders are
#     repointed to the tenant name alongside the uppercase placeholders,
#   * invalid (non-DNS-1123) names are rejected without mutating anything,
#   * no stray sed temp files are left behind, and
#   * the renamed scaffold still `kubectl kustomize`-builds (CI only).
#
# It runs the script against a throwaway copy so the real working tree is never
# mutated. Run locally with `sh scripts/rename-placeholders.test.sh`; CI runs it
# via .github/workflows/validate-scaffold.yaml.
set -eu

NAME="my-tenant" # valid DNS-1123 label with a dash; distinct from every literal

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# Build a throwaway copy of the working tree so the real tree is never mutated
# (the script now targets the scaffold owning it, i.e. this copy). The copy is
# its own git repo so check 7's `git status` works.
work="$(mktemp -d)"
other="$(mktemp -d)"
caller_repo="$(mktemp -d)"
trap 'rm -rf "$work" "$other" "$caller_repo"' EXIT
cp -R "$repo_root"/. "$work"/
rm -rf "$work/.git"
cd "$work"
git init -q

script="./scripts/rename-placeholders.sh"
deploy="deploy"

# --- Guardrails: each must reject and exit non-zero, mutating nothing ----------
snapshot_before="$(cat "$deploy"/*.yaml)"
for bad in "My Tenant" "UPPER" "-bad" "bad-" "with_underscore"; do
	if "$script" "$bad" >/dev/null 2>&1; then
		fail "expected rejection of invalid DNS-1123 name: '$bad'"
	fi
done
[ "$(cat "$deploy"/*.yaml)" = "$snapshot_before" ] ||
	fail "a rejected invocation modified deploy/ — guardrails must bail out first"

homepage_route_contract() {
	yq eval -e '
		.metadata.annotations."gethomepage.dev/enabled" == "true" and
		.metadata.annotations."gethomepage.dev/name" == "app" and
		.metadata.annotations."gethomepage.dev/description" == "Tenant application." and
		.metadata.annotations."gethomepage.dev/group" == "Customer Sites" and
		.metadata.annotations."gethomepage.dev/icon" == "mdi-application" and
		.metadata.annotations."gethomepage.dev/href" == "https://app.platform.devantler.tech" and
		.metadata.annotations."gethomepage.dev/pod-selector" == "app.kubernetes.io/name=app"
	' "$1" >/dev/null 2>&1
}

homepage_route_contract "$deploy/httproute.yaml" ||
	fail "scaffold HTTPRoute does not expose the complete Homepage discovery contract"

for annotation in href pod-selector; do
	mutant="${work}/homepage-${annotation}-mutant.yaml"
	yq eval "del(.metadata.annotations.\"gethomepage.dev/${annotation}\")" \
		"$deploy/httproute.yaml" > "$mutant"
	if homepage_route_contract "$mutant"; then
		fail "Homepage contract accepted a route without gethomepage.dev/${annotation}"
	fi
done

# Add unrelated YAML fields that use the same literal values. The onboarding
# helper must only rename the SecretStore tenant identity, not every role/name
# key it happens to encounter in deploy/.
scope_fixture="$deploy/rename-scope-fixture.yaml"
printf '%s\n' \
	'example:' \
	'  role: "replace-me"' \
	'  name: "replace-me"' > "$scope_fixture"
scope_before="$(cat "$scope_fixture")"

# A tenant may add arbitrary custom hostnames beside the two Platform domains.
# The helper must leave those values byte-identical.
# Include both complete Platform suffixes plus a prefixed reserved token so a
# substring replacement is rejected, not only a replacement of every "app".
custom_local_hostname="custom-app.platform.lan"
custom_prod_hostname="custom-app.platform.devantler.tech"
custom_description="Custom tenant presentation."
custom_group="Custom applications"
custom_icon="mdi-test-tube"
yq eval ".spec.hostnames += [\"${custom_local_hostname}\", \"${custom_prod_hostname}\"] |
	.metadata.annotations.\"gethomepage.dev/description\" = \"${custom_description}\" |
	.metadata.annotations.\"gethomepage.dev/group\" = \"${custom_group}\" |
	.metadata.annotations.\"gethomepage.dev/icon\" = \"${custom_icon}\"" \
	"$deploy/httproute.yaml" > "$deploy/httproute-with-custom.yaml"
mv "$deploy/httproute-with-custom.yaml" "$deploy/httproute.yaml"

# --- Happy path ---------------------------------------------------------------
"$script" "$NAME" >/dev/null

all="$(cat "$deploy"/*.yaml)"

# 1) REPLACE_ME fully repointed (container image + OpenBao KV path); none remain.
printf '%s\n' "$all" | grep -qF "ghcr.io/devantler-tech/${NAME}:latest" ||
	fail "container image REPLACE_ME not repointed to ${NAME}"
printf '%s\n' "$all" | grep -qF "apps/${NAME}/config" ||
	fail "OpenBao KV path REPLACE_ME not repointed to ${NAME}"
printf '%s\n' "$all" | grep -qF "REPLACE_ME" &&
	fail "a REPLACE_ME placeholder survived the rename"

# 2) Every `app`-as-a-VALUE renamed; no bare `: app` value anywhere afterwards.
printf '%s\n' "$all" | grep -qE ': app$' &&
	fail "a bare ': app' value survived the rename"
printf '%s\n' "$all" | grep -qF "${NAME}.platform.lan" ||
	fail "HTTPRoute hostname app.platform.lan not renamed"
printf '%s\n' "$all" | grep -qF "${NAME}.platform.devantler.tech" ||
	fail "HTTPRoute hostname app.platform.devantler.tech not renamed"
for custom_hostname in "$custom_local_hostname" "$custom_prod_hostname"; do
	printf '%s\n' "$all" | grep -qF "${custom_hostname}" ||
		fail "custom HTTPRoute hostname was changed by the Platform-domain rename"
done

for field_and_value in \
	"name=${NAME}" \
	"href=https://${NAME}.platform.devantler.tech" \
	"pod-selector=app.kubernetes.io/name=${NAME}" \
	"description=${custom_description}" \
	"group=${custom_group}" \
	"icon=${custom_icon}"; do
	field="${field_and_value%%=*}"
	expected="${field_and_value#*=}"
	actual="$(yq eval ".metadata.annotations.\"gethomepage.dev/${field}\"" "$deploy/httproute.yaml")"
	[ "$actual" = "$expected" ] ||
		fail "Homepage ${field} expected '${expected}' after rename, found '${actual}'"
done

# 3) The `app.kubernetes.io/name` label KEY is preserved; only its VALUE changed.
printf '%s\n' "$all" | grep -qF "app.kubernetes.io/name: ${NAME}" ||
	fail "label value not renamed to ${NAME}"
printf '%s\n' "$all" | grep -qF "app.kubernetes.io/name: app" &&
	fail "an unrenamed 'app' label value survived"
# The literal key token must still be present and uncorrupted (the value-anchored
# sed must not have rewritten the `app.` inside the key).
printf '%s\n' "$all" | grep -qF "app.kubernetes.io/name" ||
	fail "the app.kubernetes.io/name label KEY was corrupted by the rename"

# 4) CloudNativePG's literal `-app` Secret suffix preserved; not double-renamed.
printf '%s\n' "$all" | grep -qF "name: ${NAME}-db-app" ||
	fail "CNPG secretKeyRef 'app-db-app' should become '${NAME}-db-app' (suffix preserved)"
printf '%s\n' "$all" | grep -qF "${NAME}-db-${NAME}" &&
	fail "CNPG '-app' suffix was double-renamed to '${NAME}-db-${NAME}'"
printf '%s\n' "$all" | grep -qF "name: ${NAME}-db" ||
	fail "CNPG Cluster name 'app-db' not renamed to '${NAME}-db'"
printf '%s\n' "$all" | grep -qF "name: ${NAME}-secrets" ||
	fail "ExternalSecret target 'app-secrets' not renamed to '${NAME}-secrets'"

# 5) The shared `openbao` SecretStore name is NOT renamed (matches no rule).
printf '%s\n' "$all" | grep -qF "name: openbao" ||
	fail "the shared 'openbao' SecretStore name must be preserved"

# 6) The lowercase `replace-me` Vault role / ServiceAccount placeholders are
#    repointed to the tenant name too; no tenant-identity placeholder survives.
grep -qE "^[[:space:]]*role: \"${NAME}\"$" "$deploy/secretstore.yaml" ||
	fail "SecretStore Vault role not renamed to ${NAME}"
if ! awk -v expected="name: \"${NAME}\"" '
	/^[[:space:]]*serviceAccountRef:[[:space:]]*$/ { in_ref = 1; next }
	in_ref && /^[[:space:]]*name:[[:space:]]*/ {
		line = $0
		sub(/^[[:space:]]*/, "", line)
		found = 1
		if (line != expected) exit 1
		exit 0
	}
	END { if (!found) exit 1 }
' "$deploy/secretstore.yaml"; then
	fail "SecretStore ServiceAccount reference not exactly ${NAME}"
fi
grep -qF "replace-me" "$deploy/secretstore.yaml" &&
	fail "a lowercase 'replace-me' tenant-identity placeholder survived the rename"
[ "$(cat "$scope_fixture")" = "$scope_before" ] ||
	fail "rename touched unrelated role/name fields"

# 7) No stray temp files left behind by the in-place sed.
if git status --porcelain --untracked-files=all | grep -q '\.rename\.'; then
	fail "stray *.rename.* temp file left behind"
fi

# 8) Idempotent: a second run with the same name changes nothing more.
"$script" "$NAME" >/dev/null
[ "$(cat "$deploy"/*.yaml)" = "$all" ] ||
	fail "a second rename mutated deploy/ — the script is not idempotent"

# 9) Cross-checkout invocation (#61): a path-qualified call from an UNRELATED
#    git checkout must rename only the scaffold owning the script, and leave the
#    caller's working tree — including its own deploy/ with the same
#    placeholders — byte-for-byte untouched.
cp -R "$repo_root"/. "$other"/
rm -rf "$other/.git"
git init -q "$other"
git init -q "$caller_repo"
cp -R "$repo_root/deploy" "$caller_repo/deploy"
caller_before="$(cat "$caller_repo"/deploy/*.yaml)"
(cd "$caller_repo" && "$other/scripts/rename-placeholders.sh" cross-tenant >/dev/null)
[ "$(cat "$caller_repo"/deploy/*.yaml)" = "$caller_before" ] ||
	fail "cross-checkout invocation mutated the CALLER's deploy/ (#61)"
cat "$other"/deploy/*.yaml | grep -qF "cross-tenant.platform.lan" ||
	fail "cross-checkout invocation did not rename the scaffold owning the script (#61)"
cat "$other"/deploy/*.yaml | grep -qF "cross-tenant.platform.devantler.tech" ||
	fail "cross-checkout invocation did not rename the production hostname (#99)"

# 10) The renamed scaffold still builds (CI has kubectl preinstalled; skip locally
#    if it is absent so the text assertions above stay runnable everywhere).
if command -v kubectl >/dev/null 2>&1; then
	kubectl kustomize "$deploy" >/dev/null ||
		fail "renamed deploy/ no longer 'kubectl kustomize'-builds"
else
	echo "note: kubectl not found — skipping the kustomize-build assertion (CI enforces it)"
fi

echo "PASS: rename-placeholders.sh end-to-end (guardrails + placeholder/app rename + label-key/CNPG-suffix/openbao invariants + idempotency + cross-checkout targeting + build)"
