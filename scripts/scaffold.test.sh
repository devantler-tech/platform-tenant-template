#!/usr/bin/env sh
# Exercise scripts/scaffold.sh for every stack, with and without tenancy, in
# disposable copies of this template, and check what each one leaves behind.
# Building and running the results is .github/workflows/validate-stacks.yaml's job.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# copy_template <dir> — copy the template's tracked and untracked, non-ignored files.
copy_template() {
	mkdir -p "$1"
	if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		(cd "$repo_root" && git ls-files -z --cached --others --exclude-standard |
			xargs -0 tar -cf - 2>/dev/null) | tar -xf - -C "$1"
	else
		(cd "$repo_root" && tar -cf - --exclude=.git .) | tar -xf - -C "$1"
	fi
	[ -f "$1/scripts/scaffold.sh" ] || fail "could not copy the template into $1"
}

# Paths the scaffold always removes, and the tenant plumbing it removes without --tenancy.
template_only='stacks .github/workflows/validate-scaffold.yaml .github/workflows/validate-stacks.yaml
scripts/scaffold.sh scripts/scaffold.test.sh scripts/rename-placeholders.sh
scripts/rename-placeholders.test.sh scripts/agent-instructions.test.sh
scripts/workflow-caller-contract.test.sh scripts/tenant-ci-contract.test.sh
scripts/pod-security-admission.test.sh scripts/pod-security-admission-contract.test.sh
scripts/tenant-rbac.test.sh scripts/tenant-rbac-contract.test.sh
scripts/platform-tenant-envelope.test.sh scripts/platform-tenant-envelope-contract.test.sh
scripts/platform-network-floor.test.sh scripts/platform-network-floor-contract.test.sh
scripts/platform-vpa-floor.test.sh scripts/platform-vpa-floor-contract.test.sh'
tenant_only='deploy Dockerfile .github/workflows/cd.yaml scripts/publish-pin-approved.sh
scripts/publish-pin-approved.test.sh scripts/workflow-caller-pin-contract.test.sh'

# ignored <ignore-file> <path> — the path, or its directory form, is a line of the ignore file.
ignored() {
	grep -Fxq -- "$2" "$1" || grep -Fxq -- "$2/" "$1"
}

# markers_in <file> — print every scaffold marker left in a file.
markers_in() {
	grep -nE '(#|<!--) (stack|tenancy|template):(begin|end)| # (tenancy|template)$' "$1" || true
}

# The marker check must see the markers the unscaffolded template carries.
for file in .github/workflows/ci.yaml .github/dependabot.yml AGENTS.md; do
	[ -n "$(markers_in "$repo_root/$file")" ] || fail "negative control: no scaffold markers found in the template's $file"
done

# Everything the scaffold removes must stay removed: template-sync skips ignored paths.
for path in $template_only; do
	ignored "$repo_root/.templatesyncignore" "$path" ||
		fail ".templatesyncignore does not list $path, so template-sync would bring it back"
done

check_common() {
	dir=$1
	for file in .github/workflows/ci.yaml .github/dependabot.yml AGENTS.md; do
		left=$(markers_in "$dir/$file")
		[ -z "$left" ] || fail "$label: scaffold markers left in $file: $left"
		yq eval '.' "$dir/$file" >/dev/null 2>&1 || [ "$file" = AGENTS.md ] ||
			fail "$label: $file is not valid YAML"
	done
	for path in $template_only; do
		[ ! -e "$dir/$path" ] || fail "$label: template-only $path was not removed"
	done
	grep -q 'scripts/scaffold.sh' "$dir/AGENTS.md" &&
		fail "$label: AGENTS.md still describes the scaffold"
	grep -q 'scripts/scaffold.sh' "$dir/.github/workflows/ci.yaml" &&
		fail "$label: ci.yaml still describes the scaffold"
	yq eval -e '
		(.jobs."ci-required-checks".needs | sort | join(","))
		== ([.jobs | keys | .[] | select(. != "ci-required-checks")] | sort | join(","))
	' "$dir/.github/workflows/ci.yaml" >/dev/null ||
		fail "$label: CI - Required Checks does not aggregate exactly the other jobs"
	yq eval -e '.jobs.stack' "$dir/.github/workflows/ci.yaml" >/dev/null ||
		fail "$label: ci.yaml has no stack job"
	# shellcheck disable=SC2016
	yq eval -e '(.updates | length) as $all | [.updates[] | select(.directory == "/" or (.directories // [] | join(",")) == "/")] | length == $all' \
		"$dir/.github/dependabot.yml" >/dev/null ||
		fail "$label: a Dependabot entry still points into the template's stacks/"
}

check_tenancy() {
	dir=$1
	for path in $tenant_only; do
		[ -e "$dir/$path" ] || fail "$label: tenant $path is missing"
	done
	yq eval -e '.jobs."delivery-inputs" and .jobs."publish-pin-approved" and .jobs."workflow-caller-pins"' \
		"$dir/.github/workflows/ci.yaml" >/dev/null || fail "$label: the tenant CI gates are missing"
	yq eval -e '[.updates[] | select(."package-ecosystem" == "docker")] | length == 1' \
		"$dir/.github/dependabot.yml" >/dev/null || fail "$label: the image's Dependabot entry is missing"
	# shellcheck disable=SC2016
	grep -Fq 'build the tenant image and render `deploy/` before merge' "$dir/AGENTS.md" ||
		fail "$label: AGENTS.md lost the delivery-input invariant"
	grep -q "name: demo-app$" "$dir/deploy/deployment.yaml" ||
		fail "$label: deploy/ was not renamed to the application"
	grep -q 'REPLACE_ME' "$dir/deploy/deployment.yaml" &&
		fail "$label: deploy/ still carries a placeholder image"
	# The scaffolded gate must satisfy the same contract as the template's own.
	sh "$repo_root/scripts/tenant-ci-contract.test.sh" --validate \
		"$dir/.github/workflows/ci.yaml" "$repo_root/.github/workflows/validate-scaffold.yaml" \
		"$repo_root/README.md" "$dir/AGENTS.md" "$repo_root/.templatesyncignore" \
		"$repo_root/docs/REFERENCE.md" || fail "$label: the scaffolded CI breaks the tenant CI contract"
}

check_plain() {
	dir=$1
	for path in $tenant_only .dockerignore; do
		[ ! -e "$dir/$path" ] || fail "$label: tenant $path was not removed"
	done
	for path in .github/workflows/cd.yaml scripts/publish-pin-approved.sh \
		scripts/publish-pin-approved.test.sh scripts/workflow-caller-pin-contract.test.sh; do
		ignored "$dir/.templatesyncignore" "$path" ||
			fail "$label: .templatesyncignore does not keep the removed $path out"
	done
	[ "$(yq eval '.jobs | keys | join(",")' "$dir/.github/workflows/ci.yaml")" = "stack,ci-required-checks" ] ||
		fail "$label: ci.yaml should hold only the stack job and its aggregate"
	yq eval -e '[.updates[] | select(."package-ecosystem" == "docker")] | length == 0' \
		"$dir/.github/dependabot.yml" >/dev/null || fail "$label: Dependabot still updates a removed image"
	grep -q 'deploy/' "$dir/AGENTS.md" && fail "$label: AGENTS.md still describes deploy/"
	true
}

check_go() {
	dir=$1
	grep -qx 'module github.com/devantler-tech/demo-app' "$dir/go.mod" || fail "$label: go.mod was not renamed"
	grep -rq 'github.com/devantler-tech/app' "$dir/go.mod" "$dir/main.go" "$dir/internal" "$dir/.golangci.yml" &&
		fail "$label: the placeholder module path is left"
	grep -q 'github.com/devantler-tech/demo-app$' "$dir/.golangci.yml" ||
		fail "$label: the depguard allowlist does not name the module"
	yq eval -e '.jobs.stack.uses | test("^devantler-tech/\\.github/\\.github/workflows/validate-go-project\\.yaml@[0-9a-f]{40}$")' \
		"$dir/.github/workflows/ci.yaml" >/dev/null || fail "$label: the Go job does not call the pinned shared validator"
	yq eval -e '[.updates[] | select(."package-ecosystem" == "gomod")] | length == 1' \
		"$dir/.github/dependabot.yml" >/dev/null || fail "$label: Go modules are not kept current"
	grep -q '^- Go, ' "$dir/AGENTS.md" || fail "$label: AGENTS.md does not describe the Go stack"
}

check_dotnet() {
	dir=$1
	for path in DemoApp.slnx src/DemoApp/DemoApp.csproj tests/DemoApp.Tests/DemoApp.Tests.csproj global.json .editorconfig; do
		[ -f "$dir/$path" ] || fail "$label: $path is missing"
	done
	[ ! -e "$dir/src/Example" ] || fail "$label: the placeholder project directory is left"
	grep -rqE 'Example([^A-Za-z0-9_]|$)' "$dir/DemoApp.slnx" "$dir/src" "$dir/tests" &&
		fail "$label: the placeholder project name is left"
	grep -q 'ExampleFeature' "$dir/src/DemoApp/FeatureFlags.cs" ||
		fail "$label: the rename rewrote an identifier that only contains the placeholder"
	grep -q '^namespace DemoApp;' "$dir/src/DemoApp/HomePage.cs" || fail "$label: the namespace was not renamed"
	# shellcheck disable=SC2016
	grep -q '`src/DemoApp`' "$dir/AGENTS.md" || fail "$label: AGENTS.md still names the placeholder project"
	if [ -f "$dir/Dockerfile" ]; then
		grep -q '"DemoApp.dll"' "$dir/Dockerfile" || fail "$label: the Dockerfile runs the placeholder assembly"
	fi
	grep -qx 'bin/' "$dir/.gitignore" || fail "$label: .NET build output is not ignored"
	yq eval -e '[.updates[] | select(."package-ecosystem" == "nuget")] | length == 1' \
		"$dir/.github/dependabot.yml" >/dev/null || fail "$label: NuGet packages are not kept current"
}

check_none() {
	dir=$1
	[ "$(yq eval '.jobs.stack.name' "$dir/.github/workflows/ci.yaml")" = Stack ] ||
		fail "$label: the placeholder stack job was replaced"
	grep -q '<language / framework>' "$dir/AGENTS.md" || fail "$label: the stack placeholders were removed"
}

for stack in go dotnet none; do
	for mode in tenancy plain; do
		label="$stack/$mode"
		dir=$work/$stack-$mode/demo-app
		copy_template "$dir"
		if [ "$mode" = tenancy ]; then
			sh "$dir/scripts/scaffold.sh" "$stack" --tenancy >"$work/out" 2>&1 ||
				{ cat "$work/out" >&2; fail "$label: scaffold failed"; }
			check_tenancy "$dir"
		else
			sh "$dir/scripts/scaffold.sh" "$stack" >"$work/out" 2>&1 ||
				{ cat "$work/out" >&2; fail "$label: scaffold failed"; }
			check_plain "$dir"
		fi
		check_common "$dir"
		"check_$stack" "$dir"
		echo "ok: $label"
	done
done

# An explicit name wins over the directory name.
dir=$work/named/checkout
copy_template "$dir"
sh "$dir/scripts/scaffold.sh" go --tenancy widget >/dev/null
grep -qx 'module github.com/devantler-tech/widget' "$dir/go.mod" || fail "explicit name: go.mod not renamed"
grep -q 'name: widget$' "$dir/deploy/deployment.yaml" || fail "explicit name: deploy/ not renamed"
echo "ok: explicit name"

# The name `example` already matches the .NET placeholder project, so nothing moves.
dir=$work/example-name/checkout
copy_template "$dir"
sh "$dir/scripts/scaffold.sh" dotnet example >"$work/out" 2>&1 ||
	{ cat "$work/out" >&2; fail "a .NET application named example did not scaffold"; }
for path in Example.slnx src/Example/Example.csproj tests/Example.Tests/Example.Tests.csproj; do
	[ -f "$dir/$path" ] || fail "example name: $path is missing"
done
grep -q '<title>example</title>' "$dir/src/Example/HomePage.cs" || fail "example name: the page title was not renamed"
echo "ok: a .NET application named example"

# refuse <description> <expected message> <scaffold arguments...> — the scaffold must
# fail with the message and leave the copy untouched.
refuse() {
	description=$1
	expected=$2
	shift 2
	dir=$work/refuse/demo-app
	rm -rf "$work/refuse"
	copy_template "$dir"
	if [ -n "$origin" ]; then
		git -C "$dir" init -q
		git -C "$dir" remote add origin "$origin"
	fi
	before=$(cd "$dir" && find . -path ./.git -prune -o -type f -print | sort | xargs cat | cksum)
	if sh "$dir/scripts/scaffold.sh" "$@" >"$work/out" 2>&1; then
		fail "refusal not enforced: $description"
	fi
	grep -qF -- "$expected" "$work/out" || {
		cat "$work/out" >&2
		fail "refused for the wrong reason: $description"
	}
	after=$(cd "$dir" && find . -path ./.git -prune -o -type f -print | sort | xargs cat | cksum)
	[ "$before" = "$after" ] || fail "a refused scaffold changed files: $description"
	echo "ok: refuses $description"
}

origin=''
refuse 'a missing stack' 'Usage: scripts/scaffold.sh'
refuse 'an unknown stack' "unknown stack 'rust'" rust
refuse 'an unknown option' "unknown option '--tenant'" go --tenant
refuse 'an extra argument' "unexpected argument 'extra'" go name extra
refuse 'an invalid name' "'My_App' is not a valid DNS-1123 label" go My_App
refuse 'a .NET name that is not an identifier' "must start with a letter" dotnet 1app
origin=https://github.com/devantler-tech/application-template.git
refuse 'the upstream template' 'this is the upstream template' go
origin=git@github.com:devantler-tech/platform-tenant-template.git
refuse 'the upstream template under its former name' 'this is the upstream template' go
origin=''

# A second run finds nothing left to scaffold.
dir=$work/again/demo-app
copy_template "$dir"
sh "$dir/scripts/scaffold.sh" none >/dev/null
mkdir -p "$dir/scripts"
cp "$repo_root/scripts/scaffold.sh" "$dir/scripts/scaffold.sh"
if sh "$dir/scripts/scaffold.sh" none >"$work/out" 2>&1; then
	fail "a second scaffold run was not refused"
fi
grep -q 'already scaffolded' "$work/out" || fail "a second run was refused for the wrong reason"
echo "ok: refuses a second run"

echo "PASS: scaffold (6 combinations, explicit name and refusals)"
