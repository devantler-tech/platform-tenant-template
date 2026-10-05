#!/usr/bin/env sh
set -eu
script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
cd_workflow=$repo_root/.github/workflows/cd.yaml
release_workflow=$repo_root/.github/workflows/release.yaml
template_sync_workflow=$repo_root/.github/workflows/template-sync.yaml
# Report the failed contract and stop before admitting a caller.
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Only the two reviewed catalogue families may supply authenticated release tags.
# Annotated tags resolve to their peeled commit; read errors fail closed.
# Resolve the exact catalogue tag, preferring an annotated tag's peeled commit.
catalogue_tag_commit() {
 case "$1" in actions|.github) ;; *) return 1 ;; esac
 if ! listing=$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags "https://github.com/devantler-tech/$1" "refs/tags/$2" "refs/tags/$2^{}" 2>&1); then
  printf 'git ls-remote failed: %s\n' "$listing" >&2
  return 1
 fi
 printf '%s\n' "$listing" |
  awk 'NF == 2 { if ($2 ~ /\^\{\}$/) peeled=$1; else plain=$1 }
   END { if (peeled != "") print peeled; else if (plain != "") print plain }' |
  grep -Ex '[0-9a-f]{40}'
}

# Check normalized SemVer, the catalogue's reviewed floor and its tag binding.
validate_version() {
 catalogue=$1
 ref=$2
 version=$3
 floor=$4
 printf '%s\n' "$version" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ||
  fail 'each catalogue pin must carry a version comment of the form vX.Y.Z'
 major=$(printf '%s' "${version#v}" | cut -d. -f1)
 minor=$(printf '%s' "${version#v}" | cut -d. -f2)
 patch=$(printf '%s' "${version#v}" | cut -d. -f3)
 floor_major=$(printf '%s' "${floor#v}" | cut -d. -f1)
 floor_minor=$(printf '%s' "${floor#v}" | cut -d. -f2)
 floor_patch=$(printf '%s' "${floor#v}" | cut -d. -f3)
 if [ "$major" -lt "$floor_major" ] ||
  { [ "$major" -eq "$floor_major" ] && [ "$minor" -lt "$floor_minor" ]; } ||
  { [ "$major" -eq "$floor_major" ] && [ "$minor" -eq "$floor_minor" ] && [ "$patch" -lt "$floor_patch" ]; }; then
  fail "devantler-tech/$catalogue is pinned to $version, older than the reviewed floor $floor"
 fi
 tag_ref=$(catalogue_tag_commit "$catalogue" "$version") ||
  fail "could not resolve refs/tags/$version on devantler-tech/$catalogue"
 [ "$tag_ref" = "$ref" ] ||
  fail "devantler-tech/$catalogue pins $ref but its version comment names $version, which is $tag_ref; the comment must name the tag of the pinned commit"
}

# Admit the publisher separately from the aligned canonical release/sync pair.
validate_pins() {
 cd_file=$1
 release_file=$2
 template_sync_file=$3
 yq eval -e '.jobs.publish.uses | test("^devantler-tech/actions/\\.github/workflows/publish-app\\.yaml@[0-9a-f]{40}$")' "$cd_file" >/dev/null ||
  fail 'the publish caller must pin legacy publish-app.yaml to a commit SHA'
 yq eval -e '.jobs.release.uses | test("^devantler-tech/\\.github/\\.github/workflows/create-release\\.yaml@[0-9a-f]{40}$")' "$release_file" >/dev/null ||
  fail 'the release caller must pin canonical create-release.yaml to a commit SHA'
 yq eval -e '.jobs."template-sync".uses | test("^devantler-tech/\\.github/\\.github/workflows/template-sync\\.yaml@[0-9a-f]{40}$")' "$template_sync_file" >/dev/null ||
  fail 'the template-sync caller must pin canonical template-sync.yaml to a commit SHA'
 # Read the immutable commit from the selected workflow's caller field.
 pinned_ref_of() { yq eval -r "$2 | sub(\".*@\"; \"\")" "$1"; }
 # Read the human version comment bound to that immutable commit.
 pinned_version_of() { yq eval -r "$2 | line_comment" "$1"; }
 cd_ref=$(pinned_ref_of "$cd_file" '.jobs.publish.uses')
 release_ref=$(pinned_ref_of "$release_file" '.jobs.release.uses')
 sync_ref=$(pinned_ref_of "$template_sync_file" '.jobs."template-sync".uses')
 [ "$release_ref" = "$sync_ref" ] || fail 'canonical release and template-sync callers must pin the same commit'
 cd_version=$(pinned_version_of "$cd_file" '.jobs.publish.uses')
 release_version=$(pinned_version_of "$release_file" '.jobs.release.uses')
 sync_version=$(pinned_version_of "$template_sync_file" '.jobs."template-sync".uses')
 [ "$release_version" = "$sync_version" ] || fail 'canonical release and template-sync callers must carry the same version comment'
 validate_version actions "$cd_ref" "$cd_version" v13.1.2
 validate_version .github "$release_ref" "$release_version" v6.1.0
 yq eval -e '.jobs.release.with."align-npm-with-consumer-contract" == true' "$release_file" >/dev/null ||
  fail 'canonical release must retain consumer npm alignment'
}
if [ "${1:-}" = --validate ]; then
 [ "$#" -eq 4 ] || fail 'usage: workflow-caller-pin-contract.test.sh --validate <cd> <release> <template-sync>'
 validate_pins "$2" "$3" "$4"
 exit 0
fi
validate_pins "$cd_workflow" "$release_workflow" "$template_sync_workflow"
mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT
mutations_run=0
# Start each negative control with independent copies of the real callers.
reset_mutation() {
 cp "$cd_workflow" "$mutation_dir/cd.yaml"
 cp "$release_workflow" "$mutation_dir/release.yaml"
 cp "$template_sync_workflow" "$mutation_dir/template-sync.yaml"
}
# Change one copied caller with the supplied YAML expression.
mutate() {
 yq eval "$2" "$mutation_dir/$1.yaml" >"$mutation_dir/mutant.yaml"
 mv "$mutation_dir/mutant.yaml" "$mutation_dir/$1.yaml"
}
# Require both refusal and its expected reason, avoiding unrelated-failure passes.
rejected() {
 mutations_run=$((mutations_run + 1))
 if rejection=$( (validate_pins "$mutation_dir/cd.yaml" "$mutation_dir/release.yaml" "$mutation_dir/template-sync.yaml") 2>&1 >/dev/null); then
  fail "mutation passed: $1"
 fi
 printf '%s\n' "$rejection" | grep -qF -- "$2" || fail "mutation rejected for the wrong reason: $1; expected '$2', got: $rejection"
}
# Run one caller-field mutation without leaking it into later scenarios.
single_mutation() {
 reset_mutation
 mutate "$2" "$3"
 rejected "$1" "$4"
}
single_mutation 'moving publisher' cd '.jobs.publish.uses = "devantler-tech/actions/.github/workflows/publish-app.yaml@main"' 'publish caller must pin'
single_mutation 'moving release' release '.jobs.release.uses = "devantler-tech/.github/.github/workflows/create-release.yaml@main"' 'release caller must pin'
single_mutation 'short sync SHA' template-sync '.jobs."template-sync".uses = "devantler-tech/.github/.github/workflows/template-sync.yaml@1234567"' 'template-sync caller must pin'
single_mutation 'legacy release rollback' release '.jobs.release.uses = "devantler-tech/actions/.github/workflows/create-release.yaml@df7fd4f83edade31c121a9de563d9a7b9b1f900d"' 'release caller must pin'
single_mutation 'wrong sync path' template-sync '.jobs."template-sync".uses |= sub("template-sync"; "publish-app")' 'template-sync caller must pin'
single_mutation 'canonical SHA divergence' release '.jobs.release.uses |= sub("@.*"; "@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")' 'must pin the same commit'
single_mutation 'canonical comment divergence' release '.jobs.release.uses line_comment = "v6.0.6"' 'must carry the same version comment'
single_mutation 'publisher leading-zero version' cd '.jobs.publish.uses line_comment = "v13.01.2"' 'version comment of the form'
single_mutation 'consumer npm alignment disabled' release '.jobs.release.with."align-npm-with-consumer-contract" = false' 'retain consumer npm alignment'
# Change a whole catalogue family to test its version floor and tag identity.
repin_mutation() {
 reset_mutation
 family=$2
 ref=$3
 version=$4
 if [ "$family" = actions ]; then
  mutate cd ".jobs.publish.uses = \"devantler-tech/actions/.github/workflows/publish-app.yaml@$ref\" | .jobs.publish.uses line_comment = \"$version\""
 else
  mutate release ".jobs.release.uses = \"devantler-tech/.github/.github/workflows/create-release.yaml@$ref\" | .jobs.release.uses line_comment = \"$version\""
  mutate template-sync ".jobs.\"template-sync\".uses = \"devantler-tech/.github/.github/workflows/template-sync.yaml@$ref\" | .jobs.\"template-sync\".uses line_comment = \"$version\""
 fi
 rejected "$1" "$5"
}
repin_mutation 'publisher below floor' actions b089a1b041cb86af22cdc57de58a4d7d258dcc32 v13.1.1 'older than the reviewed floor'
repin_mutation 'publisher forged version' actions b089a1b041cb86af22cdc57de58a4d7d258dcc32 v13.1.3 'the comment must name the tag'
repin_mutation 'canonical below floor' .github 4b00bd6698af033dc472b39a7e609173fe38dfb1 v6.0.6 'older than the reviewed floor'
repin_mutation 'canonical forged version' .github 4b00bd6698af033dc472b39a7e609173fe38dfb1 v6.1.0 'the comment must name the tag'
repin_mutation 'canonical leading-zero version' .github e271b7ff25d4ce97b067612e7ba0c5d657b6a17a v6.01.0 'version comment of the form'
repin_mutation 'canonical nonexistent version' .github e271b7ff25d4ce97b067612e7ba0c5d657b6a17a v99.0.0 'could not resolve refs/tags/v99.0.0'
printf 'PASS: portable mixed-catalogue pin contract (happy path + %s safety mutations)\n' "$mutations_run"
