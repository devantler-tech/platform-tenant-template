#!/usr/bin/env sh
# Refuse a publish-app.yaml pin the platform has not approved yet.
#
# Usage: sh scripts/publish-pin-approved.sh <base-cd.yaml> <head-cd.yaml>
#
# The platform verifies each release against the publish-app.yaml revisions it has recorded for this
# tenant in devantler-tech/platform scripts/publish-workflow-approved-revisions.tsv. A pin that moves
# to a revision missing from that set would ship a release the platform refuses to deploy. This check
# stops the pin move instead, so a lost race parks a dependency PR rather than failing a release.
#
# An unchanged pin passes without reading the platform. A moved pin passes only when it equals the
# tenant's applied signer, main pin or release candidate. Anything unreadable fails closed.
#
# Environment:
#   PUBLISH_PIN_CONSUMER      the tenant's row in the set (default: the repository name in
#                             GITHUB_REPOSITORY)
#   PUBLISH_PIN_APPROVED_SET  a local copy of the set, instead of reading platform main (tests)

set -eu

approved_set_url=https://raw.githubusercontent.com/devantler-tech/platform/main/scripts/publish-workflow-approved-revisions.tsv
regenerate_workflow=https://github.com/devantler-tech/platform/actions/workflows/regenerate-publish-workflow-approved-revisions.yaml

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

[ "$#" -eq 2 ] || fail 'usage: publish-pin-approved.sh <base-cd.yaml> <head-cd.yaml>'

# The revision a cd.yaml pins publish-app.yaml to, validated as a full commit SHA.
publish_pin() {
	[ -f "$1" ] || fail "no cd.yaml at $1"
	uses=$(yq eval -r '.jobs.publish.uses // ""' "$1") ||
		fail "could not read the publish-app.yaml pin from $1"
	# Validate the whole reference first: a bare SHA, or another workflow pinned by SHA, is not a
	# publish-app.yaml pin.
	printf '%s\n' "$uses" | grep -Eqx 'devantler-tech/actions/\.github/workflows/publish-app\.yaml@[0-9a-f]{40}' ||
		fail "$1 does not pin devantler-tech/actions/.github/workflows/publish-app.yaml to a commit SHA"
	printf '%s\n' "${uses##*@}"
}

base_pin=$(publish_pin "$1")
head_pin=$(publish_pin "$2")

if [ "$base_pin" = "$head_pin" ]; then
	printf 'publish-app.yaml pin unchanged at %s; nothing to check.\n' "$head_pin"
	exit 0
fi

consumer=${PUBLISH_PIN_CONSUMER:-${GITHUB_REPOSITORY:-}}
consumer=${consumer##*/}
[ -n "$consumer" ] || fail 'set PUBLISH_PIN_CONSUMER or GITHUB_REPOSITORY to name this tenant'

if [ -n "${PUBLISH_PIN_APPROVED_SET:-}" ]; then
	approved_set=$(cat "$PUBLISH_PIN_APPROVED_SET") ||
		fail "could not read $PUBLISH_PIN_APPROVED_SET"
else
	approved_set=$(curl -fsSL --retry 3 "$approved_set_url") ||
		fail "could not read the platform's approved set from $approved_set_url"
fi

# Columns are found by header name, so a reordered set still reads correctly and a set without one
# of them fails instead of comparing against the wrong field.
approved=$(printf '%s\n' "$approved_set" | awk -F '\t' -v consumer="$consumer" '
	NR == 1 {
		for (i = 1; i <= NF; i++) { seen[$i]++; col[$i] = i }
		split("consumer workflow applied_signer_sha main_pin_sha release_candidate_sha", required, " ")
		for (r in required) if (seen[required[r]] > 1) { bad = 1; exit }
		if (!col["consumer"] || !col["workflow"] || !col["applied_signer_sha"] ||
			!col["main_pin_sha"] || !col["release_candidate_sha"]) { bad = 1; exit }
		next
	}
	$col["consumer"] == consumer && $col["workflow"] == "publish-app" {
		rows++
		split("applied_signer_sha main_pin_sha release_candidate_sha", fields, " ")
		for (f = 1; f <= 3; f++) {
			value = $col[fields[f]]
			if (value != "-" && (length(value) != 40 || value !~ /^[0-9a-f]+$/)) malformed = 1
			print value
		}
	}
	END {
		if (bad) print "ERROR:header"
		else if (malformed) print "ERROR:field"
		else if (rows == 0) print "ERROR:none"
		else if (rows > 1) print "ERROR:many"
	}')

case $approved in
*ERROR:header*)
	fail "the approved set must carry each of the consumer, workflow, applied_signer_sha, main_pin_sha and release_candidate_sha columns exactly once" ;;
*ERROR:field*)
	fail "the approved set's publish-app row for $consumer has a revision that is neither - nor a 40-character commit SHA" ;;
*ERROR:none*)
	fail "the approved set has no publish-app row for $consumer" ;;
*ERROR:many*)
	fail "the approved set has more than one publish-app row for $consumer" ;;
esac

# `-` marks an empty column and never matches, because head_pin was validated as 40 hex.
if printf '%s\n' "$approved" | grep -Fqx "$head_pin"; then
	printf 'publish-app.yaml pin %s is approved for %s.\n' "$head_pin" "$consumer"
	exit 0
fi

fail "publish-app.yaml pin $head_pin is not in the platform's approved set for $consumer yet, so a release signed by it would not deploy. Wait for the platform's daily regeneration, or dispatch $regenerate_workflow and merge its PR, then re-run this check."
