#!/usr/bin/env sh
# scaffold.sh — turn a repository created from this template into your application.
#
# Usage: scripts/scaffold.sh <go|dotnet|none> [--tenancy] [name]
#
#   go, dotnet  lay that stack's source, tests, lint config, Dockerfile and CI job
#               over the template, from stacks/<stack>/.
#   none        keep the placeholder CI job and Dockerfile and bring your own stack.
#   --tenancy   make the application a devantler-tech platform tenant: keep deploy/,
#               the signed CD publish and the CI gates that guard it, renamed to the
#               application. Without it, all of them are removed.
#   name        the application and repository name, a DNS-1123 label. Defaults to
#               the name of the directory this script's repository is in.
#
# It runs once: it removes stacks/ and the template's own validation, so a second
# run refuses. Review the result with `git status` and `git diff`.
set -eu

# Resolve the repository that owns this script, never the caller's working directory.
script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")

fail() {
	echo "error: $*" >&2
	exit 1
}

usage() {
	sed -n '4,13p' "$script_dir/scaffold.sh" | sed 's/^# \{0,1\}//'
}

stack=''
tenancy=0
name=''
for arg in "$@"; do
	case $arg in
	--tenancy) tenancy=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	-*) fail "unknown option '$arg' (see --help)" ;;
	*)
		if [ -z "$stack" ]; then
			stack=$arg
		elif [ -z "$name" ]; then
			name=$arg
		else
			fail "unexpected argument '$arg' (see --help)"
		fi
		;;
	esac
done

if [ -z "$stack" ]; then
	usage >&2
	exit 1
fi
case $stack in
go | dotnet | none) ;;
*) fail "unknown stack '$stack': choose go, dotnet or none" ;;
esac

name=${name:-$(basename -- "$repo_root")}
if ! printf '%s' "$name" | grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'; then
	fail "'$name' is not a valid DNS-1123 label (lower-case alphanumerics and '-', starting and ending alphanumeric); pass a name, e.g. scripts/scaffold.sh $stack my-app"
fi

# A .NET project name is the PascalCase form of the application name. Check it
# before changing anything, so a refused name never leaves a half-made scaffold.
if [ "$stack" = dotnet ]; then
	project=$(printf '%s' "$name" | awk 'BEGIN { RS = "-"; ORS = "" } length($0) > 0 { print toupper(substr($0, 1, 1)) substr($0, 2) }')
	printf '%s' "$project" | grep -Eq '^[A-Z][A-Za-z0-9]*$' ||
		fail "'$name' gives the .NET project name '$project', which must start with a letter"
fi

[ -d "$repo_root/stacks" ] ||
	fail "$repo_root/stacks not found: this repository is already scaffolded"

origin=$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)
case $origin in
*devantler-tech/application-template | *devantler-tech/application-template.git | \
	*devantler-tech/platform-tenant-template | *devantler-tech/platform-tenant-template.git)
	fail "this is the upstream template; run the scaffold in a repository created from it"
	;;
esac

# rewrite <file> <awk program> [awk assignments...] — run awk over a file in place.
rewrite() {
	file=$1
	program=$2
	shift 2
	awk "$@" "$program" "$file" >"$file.scaffold.$$"
	mv "$file.scaffold.$$" "$file"
}

# A marker is a `# <tag>:begin` / `# <tag>:end` or `<!-- <tag>:begin -->` /
# `<!-- <tag>:end -->` line around a block, or a `# <tag>` suffix on a single line.

# drop <tag> <file> — delete every block and line marked <tag>, and squeeze the
# blank lines left behind.
drop() {
	# shellcheck disable=SC2016
	rewrite "$2" '
		$0 ~ "(#|<!--) " tag ":begin" { skip = 1; next }
		$0 ~ "(#|<!--) " tag ":end" { skip = 0; next }
		skip { next }
		$0 ~ " # " tag "$" { next }
		/^$/ { if (blank) next; blank = 1; print; next }
		{ blank = 0; print }
	' -v tag="$1"
}

# keep <tag> <file> — keep what is marked <tag> and delete only its markers.
keep() {
	# shellcheck disable=SC2016
	rewrite "$2" '
		$0 ~ "(#|<!--) " tag ":(begin|end)" { next }
		{ sub(" # " tag "$", ""); print }
	' -v tag="$1"
}

# replace <tag> <file> <content-file> — replace the block marked <tag> with the
# content of <content-file>, markers included.
replace() {
	[ -s "$3" ] || fail "$3 is empty"
	# shellcheck disable=SC2016
	rewrite "$2" '
		$0 ~ "(#|<!--) " tag ":begin" {
			while ((getline line < content) > 0) print line
			skip = 1
			next
		}
		$0 ~ "(#|<!--) " tag ":end" { skip = 0; next }
		skip { next }
		{ print }
	' -v tag="$1" -v content="$3"
}

# substitute <sed script> <file...> — apply a sed script to files in place.
substitute() {
	script=$1
	shift
	for file in "$@"; do
		sed "$script" "$file" >"$file.scaffold.$$"
		mv "$file.scaffold.$$" "$file"
	done
}

cd "$repo_root"
ci=.github/workflows/ci.yaml
dependabot=.github/dependabot.yml
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- 1. The stack -----------------------------------------------------------
if [ "$stack" = none ]; then
	keep stack "$ci"
	keep stack AGENTS.md
else
	source_dir=stacks/$stack
	# Copy the stack's files over the template. The fragments are merged below,
	# not copied, and build output from a local build is skipped.
	(cd "$source_dir" && find . -type f) | while IFS= read -r file; do
		case $file in
		./AGENTS.fragment.md | ./dependabot.fragment.yml | ./.gitignore | \
			./.github/workflows/ci-job.yaml | */bin/* | */obj/* | */TestResults/*)
			continue
			;;
		esac
		mkdir -p "$(dirname -- "$file")"
		cp "$source_dir/$file" "$file"
	done

	# The stack's CI job is everything after `jobs:` in its ci-job.yaml.
	awk 'found { print } /^jobs:$/ { found = 1 }' "$source_dir/.github/workflows/ci-job.yaml" >"$work/job.yaml"
	replace stack "$ci" "$work/job.yaml"
	replace stack AGENTS.md "$source_dir/AGENTS.fragment.md"
	{
		echo
		cat "$source_dir/dependabot.fragment.yml"
	} >>"$dependabot"
	if [ -f "$source_dir/.gitignore" ]; then
		{
			echo
			cat "$source_dir/.gitignore"
		} >>.gitignore
	fi

	case $stack in
	go)
		substitute "s#github\\.com/devantler-tech/app\\([/\"]\\)#github.com/devantler-tech/$name\\1#g; s#github\\.com/devantler-tech/app\$#github.com/devantler-tech/$name#; s#pageTitle = \"app\"#pageTitle = \"$name\"#; s#flagDomain = \"app\"#flagDomain = \"$name\"#" \
			go.mod main.go .golangci.yml internal/server/server.go internal/server/server_test.go \
			internal/featureflag/featureflag.go internal/featureflag/featureflag_test.go
		;;
	dotnet)
		mv src/Example "src/$project"
		mv "src/$project/Example.csproj" "src/$project/$project.csproj"
		mv tests/Example.Tests "tests/$project.Tests"
		mv "tests/$project.Tests/Example.Tests.csproj" "tests/$project.Tests/$project.Tests.csproj"
		mv Example.slnx "$project.slnx"
		# Rename `Example` only where it stands alone (namespaces, paths, assembly
		# names), never inside a longer identifier such as ExampleFeature.
		find "src/$project" "tests/$project.Tests" -type f \( -name '*.cs' -o -name '*.csproj' \) >"$work/dotnet-files"
		# The file list holds only paths this script created, none with spaces.
		# shellcheck disable=SC2046
		substitute "s/Example\\([^A-Za-z0-9_]\\)/$project\\1/g; s/Example\$/$project/; s#<title>app</title>#<title>$name</title>#" \
			"$project.slnx" Dockerfile AGENTS.md $(cat "$work/dotnet-files")
		;;
	esac
fi

# --- 2. Tenancy ---------------------------------------------------------------
if [ "$tenancy" -eq 1 ]; then
	keep tenancy "$ci"
	keep tenancy "$dependabot"
	keep tenancy AGENTS.md
	sh scripts/rename-placeholders.sh "$name"
else
	drop tenancy "$ci"
	drop tenancy "$dependabot"
	drop tenancy AGENTS.md
	rm -rf deploy Dockerfile .dockerignore .github/workflows/cd.yaml \
		scripts/publish-pin-approved.sh scripts/publish-pin-approved.test.sh \
		scripts/workflow-caller-pin-contract.test.sh
	# Keep template-sync from bringing the removed tenant plumbing back.
	cat >>.templatesyncignore <<'EOF'

# --- Not a platform tenant (scaffolded without --tenancy) ---
# Remove these lines, and copy the files back from the template, to become one.
.github/workflows/cd.yaml
scripts/publish-pin-approved.sh
scripts/publish-pin-approved.test.sh
scripts/workflow-caller-pin-contract.test.sh
EOF
fi

# --- 3. The template's own machinery -------------------------------------------
# Only this template uses these. .templatesyncignore lists each of them, so
# template-sync never brings them back.
drop template "$ci"
drop template "$dependabot"
drop template AGENTS.md
rm -rf stacks .github/workflows/validate-scaffold.yaml .github/workflows/validate-stacks.yaml \
	scripts/scaffold.sh scripts/scaffold.test.sh \
	scripts/rename-placeholders.sh scripts/rename-placeholders.test.sh \
	scripts/agent-instructions.test.sh scripts/workflow-caller-contract.test.sh \
	scripts/tenant-ci-contract.test.sh \
	scripts/pod-security-admission.test.sh scripts/pod-security-admission-contract.test.sh \
	scripts/tenant-rbac.test.sh scripts/tenant-rbac-contract.test.sh \
	scripts/platform-tenant-envelope.test.sh scripts/platform-tenant-envelope-contract.test.sh \
	scripts/platform-network-floor.test.sh scripts/platform-network-floor-contract.test.sh \
	scripts/platform-vpa-floor.test.sh scripts/platform-vpa-floor-contract.test.sh
rmdir scripts 2>/dev/null || true

tenant=no
[ "$tenancy" -eq 0 ] || tenant=yes
echo "Scaffolded '$name' (stack: $stack, platform tenant: $tenant)."
echo "Next: review 'git status' and 'git diff', replace README.md and CONTRIBUTING.md with your own,"
echo "and fill in the remaining placeholders in AGENTS.md."
