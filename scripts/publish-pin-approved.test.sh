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
    uses: devantler-tech/actions/.github/workflows/publish-app.yaml@$2 # v13.6.5
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

# expect <name> <exit> <text> <set> <head-pin> [consumer]
expect() {
	name=$1 want_status=$2 want_text=$3 set=$4 head=$5 consumer=${6:-example-tenant}
	cd_file base.yaml "$main_pin"
	cd_file head.yaml "$head"
	status=0
	output=$(PUBLISH_PIN_CONSUMER=$consumer PUBLISH_PIN_APPROVED_SET=$set \
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
expect 'a set without the release candidate column fails closed' 1 'lacks a consumer' "$work/old.tsv" "$candidate"

set_file empty.tsv "$(row example-tenant "$applied" "$main_pin" -)"
expect 'an empty candidate column never matches' 1 'is not in' "$work/empty.tsv" "$candidate"

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

printf 'publish-pin-approved: %s passed, %s failed\n' "$pass" "$failures"
completed=1
[ "$failures" -eq 0 ]
