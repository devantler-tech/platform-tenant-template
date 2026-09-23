#!/usr/bin/env sh
# rename-placeholders.sh — turn this scaffold into a real tenant in one shot.
#
# The deploy/ manifests ship with three placeholder forms that collapse to one
# value — your tenant (repository) name:
#   • `app`       — the example app/resource name (Deployment, Service, the
#                   `app.kubernetes.io/name` label *value*, HTTPRoute, the CNPG
#                   Cluster, its database/owner, Platform hostnames, and Homepage
#                   discovery identity).
#   • REPLACE_ME  — the container image and OpenBao path.
#   • replace-me  — the tenant's Vault role and ServiceAccount.
# (Per the template convention the Deployment container `name` MUST equal the
# repository name — see docs/REFERENCE.md — so a single name drives everything.)
#
# Doing this by hand is easy to get half-wrong; this script renames all three
# across deploy/*.yaml in place WITHOUT corrupting the parts that must NOT
# change:
#   • the `app.kubernetes.io/name` label *key* (only its value is renamed),
#   • CloudNativePG's literal `-app` suffix on its generated secret, and
#   • the shared `openbao` SecretStore name.
#
# Usage:  scripts/rename-placeholders.sh [tenant-name]
# With no argument it defaults to the scaffold's directory name.
set -eu

# Resolve the scaffold that OWNS this script — never the caller's checkout. The
# helper may be invoked by path from another repository (or any directory), and
# a cwd-derived root (git rev-parse --show-toplevel) would rewrite THAT tree's
# deploy/ instead of this one's (#61). `cd -P` pins directory symlinks to their
# physical path; a symlink to the script itself intentionally resolves relative
# to the symlink's own directory (POSIX sh has no portable readlink).
script_dir="$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)"
repo_root="$(dirname -- "$script_dir")"
name="${1:-$(basename "$repo_root")}"

# k8s resource names and the container name must be a DNS-1123 label.
if ! printf '%s' "$name" | grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'; then
  echo "error: '$name' is not a valid DNS-1123 label" >&2
  echo "       (lower-case alphanumerics and '-'; must start and end alphanumeric)." >&2
  echo "       pass an explicit name, e.g.: scripts/rename-placeholders.sh my-tenant" >&2
  exit 1
fi

deploy_dir="$repo_root/deploy"
[ -d "$deploy_dir" ] || {
  echo "error: $deploy_dir not found — the scaffold owning this script has no deploy/ directory." >&2
  exit 1
}

changed=0
for f in "$deploy_dir"/*.yaml; do
  [ -f "$f" ] || continue
  tmp="$f.rename.$$"
  # Order matters: the longer CNPG-secret suffix is handled before `app-db`, and
  # every `app*` rule is anchored to a complete YAML *value* (": …$" or an
  # exact list item, optionally followed by a comment), so label keys, custom
  # hostnames, and prose/comments are not touched.
  sed \
    -e "s/REPLACE_ME/$name/g" \
    -e "/^[[:space:]]*kubernetes:[[:space:]]*$/,/^[[:space:]]*serviceAccountRef:[[:space:]]*$/s/^\([[:space:]]*role:[[:space:]]*\)\"replace-me\"$/\1\"$name\"/" \
    -e "/^[[:space:]]*serviceAccountRef:[[:space:]]*$/,/^[[:space:]]*name:[[:space:]]*/s/^\([[:space:]]*name:[[:space:]]*\)\"replace-me\"$/\1\"$name\"/" \
    -e "s/: app-db-app\$/: $name-db-app/" \
    -e "s/: app-db\$/: $name-db/" \
    -e "s/: app-secrets\$/: $name-secrets/" \
    -e "s/^\\([[:space:]]*-[[:space:]]*\\)app\\.platform\\.lan$/\\1$name.platform.lan/" \
    -e "s/^\\([[:space:]]*-[[:space:]]*\\)app\\.platform\\.lan\\([[:space:]]*#.*\\)$/\\1$name.platform.lan\\2/" \
    -e "s/^\\([[:space:]]*-[[:space:]]*\\)app\\.platform\\.devantler\\.tech$/\\1$name.platform.devantler.tech/" \
    -e "s/^\\([[:space:]]*-[[:space:]]*\\)app\\.platform\\.devantler\\.tech\\([[:space:]]*#.*\\)$/\\1$name.platform.devantler.tech\\2/" \
    -e "s|^\\([[:space:]]*gethomepage\\.dev/href:[[:space:]]*https://\\)app\\(\\.platform\\.devantler\\.tech\\)$|\\1$name\\2|" \
    -e "s|^\\([[:space:]]*gethomepage\\.dev/pod-selector:[[:space:]]*app\\.kubernetes\\.io/name=\\)app$|\\1$name|" \
    -e "s/: app\$/: $name/" \
    "$f" > "$tmp"
  if cmp -s "$f" "$tmp"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$f"
    changed=$((changed + 1))
  fi
done

echo "Renamed placeholders to '$name' across $changed file(s) in deploy/."
echo "Next: review with 'git diff', then 'kubectl kustomize deploy/' to confirm it builds."
