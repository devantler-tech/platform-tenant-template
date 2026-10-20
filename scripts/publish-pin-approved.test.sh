#!/usr/bin/env sh
# Tests for scripts/publish-pin-approved.sh. Every case reads a local approved set, never the network.

set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
subject=$script_dir/publish-pin-approved.sh
work=$(mktemp -d)
# An abort must not read as a pass: some shells report exit 0 from an EXIT trap after set -e fires.
completed=0
trap 'rm -rf "$work"; [ "$completed" -eq 1 ] || exit 1' EXIT

applied=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
main_pin=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
candidate=cccccccccccccccccccccccccccccccccccccccc
unapproved=dddddddddddddddddddddddddddddddddddddddd
tab=$(printf '\t')

pass=0
failures=0

cd_file() {
	cat >"$work/$1" <<EOF
name: CD
jobs:
  publish:
    uses: devantler-tech/${3:-actions}/.github/workflows/publish-app.yaml@$2 # fixture
EOF
}

set_file() {
	name=$1
	shift
	printf 'consumer%sworkflow%sapplied_tag%sapplied_digest%sapplied_signer_sha%smain_pin_sha%srelease_candidate_sha%sobserved_on\n' \
		"$tab" "$tab" "$tab" "$tab" "$tab" "$tab" "$tab" >"$work/$name"
	for row in "$@"; do
		printf '%s\n' "$row" >>"$work/$name"
	done
}

row() {
	printf '%s%spublish-app%s1.0.0%ssha256:0%s%s%s%s%s%s%s2026-09-21' \
		"$1" "$tab" "$tab" "$tab" "$tab" "$2" "$tab" "$3" "$tab" "$4" "$tab"
}

canonical_file() {
	printf 'consumer\tworkflow\trepository\tcommit\n' >"$work/canonical.tsv"
	for canonical_row in "$@"; do printf '%s\n' "$canonical_row" >>"$work/canonical.tsv"; done
}
canonical_row() { printf '%s\tpublish-app\tdevantler-tech/.github\t%s' "$1" "$2"; }

# expect <name> <exit> <text> <set> <head-pin> [consumer] [head-family] [base-family]
expect() {
	name=$1 want_status=$2 want_text=$3 set=$4 head=$5 consumer=${6:-example-tenant}
	cd_file base.yaml "$main_pin" "${8:-actions}"
	cd_file head.yaml "$head" "${7:-actions}"
	status=0
	output=$(PUBLISH_PIN_CONSUMER=$consumer PUBLISH_PIN_APPROVED_SET=$set PUBLISH_PIN_CANONICAL_SET=$work/canonical.tsv \
		sh "$subject" "$work/base.yaml" "$work/head.yaml" 2>&1) || status=$?
	if [ "$status" -eq "$want_status" ] && printf '%s\n' "$output" | grep -Fq -- "$want_text"; then
		pass=$((pass + 1))
	else
		printf 'FAIL: %s (exit %s, want %s)\n%s\n' "$name" "$status" "$want_status" "$output" >&2
		failures=$((failures + 1))
	fi
}

set_file ok.tsv "$(row example-tenant "$applied" "$main_pin" "$candidate")" "$(row other-tenant "$unapproved" "$unapproved" "$unapproved")"

expect 'an unchanged pin passes without reading the set' 0 'unchanged' "$work/missing.tsv" "$main_pin"
expect 'a pin moved to the release candidate passes' 0 "pin $candidate is approved for example-tenant" "$work/ok.tsv" "$candidate"
expect 'a pin moved to the applied signer passes' 0 'is approved' "$work/ok.tsv" "$applied"
expect 'a pin moved to an unapproved revision fails and names it' 1 "pin $unapproved is not in the platform's approved set for example-tenant" "$work/ok.tsv" "$unapproved"
expect 'the failure says how to unblock it' 1 'regenerate-publish-workflow-approved-revisions' "$work/ok.tsv" "$unapproved"
expect "another tenant's approved revision does not count" 1 'is not in' "$work/ok.tsv" "$unapproved"
expect 'a tenant with no row fails closed' 1 'no publish-app row for missing-tenant' "$work/ok.tsv" "$candidate" missing-tenant
expect 'an unreadable set fails closed' 1 'could not read' "$work/missing.tsv" "$candidate"

set_file dup.tsv "$(row example-tenant "$applied" "$main_pin" "$candidate")" "$(row example-tenant "$applied" "$main_pin" "$candidate")"
expect 'duplicate rows fail closed' 1 'more than one publish-app row' "$work/dup.tsv" "$candidate"

printf 'consumer%sworkflow%sapplied_signer_sha%smain_pin_sha\n%s\n' "$tab" "$tab" "$tab" \
	"example-tenant${tab}publish-app${tab}${candidate}${tab}${main_pin}" >"$work/old.tsv"
expect 'a set without the release candidate column fails closed' 1 'exactly once' "$work/old.tsv" "$candidate"

set_file empty.tsv "$(row example-tenant "$applied" "$main_pin" -)"
expect 'an empty candidate column never matches' 1 'is not in' "$work/empty.tsv" "$candidate"

# A malformed revision alongside the approved one must not let the row pass.
set_file bad-field.tsv "$(row example-tenant "$applied" "$main_pin" "$candidate")"
sed "s/$main_pin/not-a-sha/" "$work/bad-field.tsv" >"$work/bad-field2.tsv"
expect 'a malformed revision field fails closed' 1 'neither - nor a 40-character commit SHA' "$work/bad-field2.tsv" "$candidate"

printf 'consumer%sworkflow%sapplied_signer_sha%smain_pin_sha%srelease_candidate_sha%smain_pin_sha\n%s\n' "$tab" "$tab" "$tab" "$tab" "$tab" \
	"example-tenant${tab}publish-app${tab}${applied}${tab}${main_pin}${tab}${candidate}${tab}${unapproved}" >"$work/dup-header.tsv"
expect 'a duplicated required column fails closed' 1 'exactly once' "$work/dup-header.tsv" "$unapproved"

cd_file base.yaml "$main_pin"
printf 'jobs:\n  publish:\n    uses: devantler-tech/actions/.github/workflows/publish-app.yaml@v13\n' >"$work/tag.yaml"
status=0
output=$(PUBLISH_PIN_CONSUMER=example-tenant PUBLISH_PIN_APPROVED_SET=$work/ok.tsv \
	sh "$subject" "$work/base.yaml" "$work/tag.yaml" 2>&1) || status=$?
if [ "$status" -eq 1 ] && printf '%s\n' "$output" | grep -Fq 'to a commit SHA'; then
	pass=$((pass + 1))
else
	printf 'FAIL: a tag pin fails closed (exit %s)\n%s\n' "$status" "$output" >&2
	failures=$((failures + 1))
fi

printf 'jobs:\n  publish:\n    uses: %s\n' "$candidate" >"$work/bare.yaml"
status=0
output=$(PUBLISH_PIN_CONSUMER=example-tenant PUBLISH_PIN_APPROVED_SET=$work/ok.tsv \
	sh "$subject" "$work/base.yaml" "$work/bare.yaml" 2>&1) || status=$?
if [ "$status" -eq 1 ] && printf '%s\n' "$output" | grep -Fq 'to a commit SHA'; then
	pass=$((pass + 1))
else
	printf 'FAIL: a bare SHA is not a publish-app.yaml pin (exit %s)\n%s\n' "$status" "$output" >&2
	failures=$((failures + 1))
fi

# Multiple valid documents used to pass a line-oriented grep and select the last
# approved SHA, rather than proving one complete publisher identity.
cd_file base.yaml "$main_pin"
cd_file head.yaml "$main_pin"
printf '\n---\n' >>"$work/head.yaml"
cd_file second.yaml "$candidate"
cat "$work/second.yaml" >>"$work/head.yaml"
status=0
output=$(PUBLISH_PIN_CONSUMER=example-tenant PUBLISH_PIN_APPROVED_SET=$work/ok.tsv \
	sh "$subject" "$work/base.yaml" "$work/head.yaml" 2>&1) || status=$?
if [ "$status" -eq 1 ] && printf '%s\n' "$output" | grep -Fq 'exactly one'; then
	pass=$((pass + 1))
else
	printf 'FAIL: multiple publisher documents were accepted or misdiagnosed\n%s\n' "$output" >&2
	failures=$((failures + 1))
fi

canonical_file "$(canonical_row example-tenant "$candidate")" "$(canonical_row other-tenant "$unapproved")"
expect 'an explicitly approved canonical publisher passes' 0 'is approved for example-tenant' "$work/missing.tsv" "$candidate" example-tenant .github
expect 'another canonical tenant does not approve this one' 1 'not in the canonical approvals for example-tenant' "$work/ok.tsv" "$unapproved" example-tenant .github
expect 'same SHA in another repository is not an unchanged identity' 1 'not in the canonical approvals for example-tenant' "$work/ok.tsv" "$main_pin" example-tenant .github
expect 'an unchanged canonical identity needs no lookup' 0 'unchanged' "$work/missing.tsv" "$main_pin" example-tenant .github .github
expect 'an unknown publisher family is rejected' 1 'to a commit SHA' "$work/ok.tsv" "$candidate" example-tenant .github-evil

canonical_file "$(canonical_row example-tenant "$candidate")" "$(canonical_row example-tenant "$main_pin")"
expect 'two distinct reviewed canonical revisions may overlap' 0 'is approved' "$work/missing.tsv" "$main_pin" example-tenant .github
canonical_file "$(canonical_row example-tenant "$candidate")" "$(canonical_row example-tenant "$main_pin")" "$(canonical_row example-tenant "$applied")"
expect 'a third canonical approval is rejected' 1 'at most two' "$work/ok.tsv" "$candidate" example-tenant .github
canonical_file "$(canonical_row example-tenant "$candidate")" "$(canonical_row example-tenant "$candidate")"
expect 'a repeated canonical commit is rejected' 1 'duplicate canonical commit' "$work/ok.tsv" "$candidate" example-tenant .github

canonical_file "example-tenant${tab}publish-app${tab}another/repository${tab}${candidate}"
expect 'another repository cannot approve a canonical identity' 1 'malformed canonical approval' "$work/ok.tsv" "$candidate" example-tenant .github
canonical_file "example-tenant${tab}publish-manifests${tab}devantler-tech/.github${tab}${candidate}"
expect 'another workflow cannot approve a canonical identity' 1 'malformed canonical approval' "$work/ok.tsv" "$candidate" example-tenant .github
canonical_file "$(canonical_row example-tenant v7.22.0)"
expect 'a floating canonical revision is rejected' 1 'malformed canonical approval' "$work/ok.tsv" "$candidate" example-tenant .github
canonical_file "$(canonical_row other-tenant "$candidate")"
expect 'a missing canonical consumer is rejected' 1 'not in the canonical approvals for example-tenant' "$work/ok.tsv" "$candidate" example-tenant .github
printf 'consumer\tworkflow\tcommit\tcommit\nexample-tenant\tpublish-app\t%s\t%s\n' "$candidate" "$candidate" >"$work/canonical.tsv"
expect 'a duplicated canonical header is rejected' 1 'canonical approval header' "$work/ok.tsv" "$candidate" example-tenant .github
printf 'commit\trepository\tworkflow\tconsumer\n%s\tdevantler-tech/.github\tpublish-app\texample-tenant\n' "$candidate" >"$work/canonical.tsv"
expect 'canonical columns are bound by header, not position' 0 'is approved' "$work/missing.tsv" "$candidate" example-tenant .github
rm "$work/canonical.tsv"
expect 'an unreadable canonical set fails closed' 1 'could not read' "$work/ok.tsv" "$candidate" example-tenant .github

printf 'publish-pin-approved: %s passed, %s failed\n' "$pass" "$failures"
completed=1
[ "$failures" -eq 0 ]
