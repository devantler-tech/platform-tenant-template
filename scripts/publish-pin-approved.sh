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
# An unchanged full identity passes without reading the platform. A legacy move requires the
# tenant's applied signer, main pin or release candidate; a maintained publisher requires an exact
# canonical approval for that tenant. The same SHA in another repository is a changed identity.
#
# Environment:
#   PUBLISH_PIN_CONSUMER      the tenant's row in the set (default: the repository name in
#                             GITHUB_REPOSITORY)
#   PUBLISH_PIN_APPROVED_SET  a local copy of the set, instead of reading platform main (tests)
#   PUBLISH_PIN_CANONICAL_SET a local canonical approval record (tests)

set -eu

approved_set_url=https://raw.githubusercontent.com/devantler-tech/platform/main/scripts/publish-workflow-approved-revisions.tsv
canonical_set_url=https://raw.githubusercontent.com/devantler-tech/platform/main/scripts/publish-workflow-canonical-approvals.tsv
regenerate_workflow=https://github.com/devantler-tech/platform/actions/workflows/regenerate-publish-workflow-approved-revisions.yaml

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

[ "$#" -eq 2 ] || fail 'usage: publish-pin-approved.sh <base-cd.yaml> <head-cd.yaml>'

# One complete publisher identity, not just a SHA that could belong to another repository.
publish_identity() {
	[ -f "$1" ] || fail "no cd.yaml at $1"
	uses=$(yq eval -r '.jobs.publish.uses // ""' "$1") ||
		fail "could not read the publish-app.yaml pin from $1"
	# Validate the whole reference first: a bare SHA, or another workflow pinned by SHA, is not a
	# publish-app.yaml pin.
	case "$uses" in
	*'
'*) fail "$1 must contain exactly one publish-app.yaml identity" ;;
	esac
	printf '%s\n' "$uses" | grep -Eqx 'devantler-tech/(actions|\.github)/\.github/workflows/publish-app\.yaml@[0-9a-f]{40}' ||
		fail "$1 does not pin a supported publish-app.yaml identity to a commit SHA"
	printf '%s\n' "$uses"
}

base_identity=$(publish_identity "$1")
head_identity=$(publish_identity "$2")
head_pin=${head_identity##*@}

if [ "$base_identity" = "$head_identity" ]; then
	printf 'publish-app.yaml pin unchanged at %s; nothing to check.\n' "$head_pin"
	exit 0
fi

consumer=${PUBLISH_PIN_CONSUMER:-${GITHUB_REPOSITORY:-}}
consumer=${consumer##*/}
[ -n "$consumer" ] || fail 'set PUBLISH_PIN_CONSUMER or GITHUB_REPOSITORY to name this tenant'

case "$head_identity" in
devantler-tech/.github/*)
	if [ -n "${PUBLISH_PIN_CANONICAL_SET:-}" ]; then
		canonical_set=$(cat "$PUBLISH_PIN_CANONICAL_SET") || fail "could not read $PUBLISH_PIN_CANONICAL_SET"
	else
		canonical_set=$(curl -fsSL --retry 3 "$canonical_set_url") || fail 'could not read the canonical approval record'
	fi
	approved=$(printf '%s\n' "$canonical_set" | awk -F '\t' -v consumer="$consumer" '
		NR==1 {
			for (i=1; i<=NF; i++) {seen[$i]++; col[$i]=i}
			split("consumer workflow repository commit", required, " ")
			for (r in required) if (seen[required[r]]!=1) bad=1
			if (NF!=4 || bad) {bad=1; exit}
			next
		}
		$col["consumer"]==consumer {
			rows++; value=$col["commit"]
			if (NF!=4 || $col["workflow"]!="publish-app" || $col["repository"]!="devantler-tech/.github" ||
				length(value)!=40 || value!~/^[0-9a-f]+$/) malformed=1
			if (commits[value]++) duplicate=1
			print value
		}
		END {
			if (bad) print "ERROR:header"
			else if (malformed) print "ERROR:field"
			else if (duplicate) print "ERROR:duplicate"
			else if (rows>2) print "ERROR:many"
		}')
	case "$approved" in
	*ERROR:header*) fail 'invalid canonical approval header' ;;
	*ERROR:field*) fail "malformed canonical approval for $consumer" ;;
	*ERROR:duplicate*) fail "duplicate canonical commit for $consumer" ;;
	*ERROR:many*) fail "canonical approvals permit at most two reviewed commits for $consumer" ;;
	esac
	if printf '%s\n' "$approved" | grep -Fqx "$head_pin"; then
		printf 'publish-app.yaml pin %s is approved for %s by the canonical publisher record.\n' "$head_pin" "$consumer"
		exit 0
	fi
	fail "publish-app.yaml pin $head_pin is not in the canonical approvals for $consumer; require its exact reviewed and deployed platform approval before repointing."
	;;
esac

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
