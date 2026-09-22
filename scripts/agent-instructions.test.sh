#!/usr/bin/env sh
# Validate the agent-maintenance contract copied into every new tenant.
#
# AGENTS.md and the maintain skill become tenant-owned immediately after a repo
# is created, so template sync cannot repair an unsafe bootstrap later. This
# test pins the safety boundaries and exercises representative bypasses.
set -eu

# Resolve the scaffold that owns this test rather than the caller's checkout.
# New tenants may invoke scaffold helpers by path from another repository, and
# a cwd-derived Git root would validate the wrong AGENTS.md.
script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

require_literal() {
	description=$1
	needle=$2
	file=$3
	# Markdown line wrapping is presentation-only; validate the prose after
	# normalising newlines so reflowing a paragraph cannot weaken this guard.
	if ! tr '\n' ' ' < "$file" | grep -Fq -- "$needle"; then
		fail "$description"
	fi
}

forbid_literal() {
	description=$1
	needle=$2
	file=$3
	if tr '\n' ' ' < "$file" | grep -Fiq -- "$needle"; then
		fail "$description"
	fi
}

forbid_pattern() {
	description=$1
	pattern=$2
	file=$3
	if tr '\n' ' ' < "$file" | grep -Eiq -- "$pattern"; then
		fail "$description"
	fi
}

validate_contract() {
	agent_contract_file=$1
	skill_contract_file=$2

	require_literal "the maintenance section must defer to the monorepo contract" \
		"this copy is stale: follow the monorepo contract" "$agent_contract_file"
	require_literal "dependency-bot issues must remain no-action" \
		"AUTOMATION-OWNED (NO-ACTION)" "$agent_contract_file"
	require_literal "Renovate and Dependabot issues must both remain in scope" \
		"Issues authored by Renovate or Dependabot" "$agent_contract_file"
	require_literal "dependency-bot issues must never be selected, edited, or closed" \
		"never select, edit, or close them" "$agent_contract_file"
	require_literal "a dependency-bot PR is left alone only while it self-progresses" \
		"only while live evidence shows it is still progressing them" \
		"$agent_contract_file"
	require_literal "a bot-branch adaptation must stay behind the draft fence" \
		"convert the pull request to draft and disable auto-merge" \
		"$agent_contract_file"
	require_literal "an adapted bot head must regain the review gate" \
		"the adapted head then needs the normal exact-head review" \
		"$agent_contract_file"
	require_literal "ownership must be verified independently of branch shape" \
		"Branch names, authors, and disclosure text do not establish ownership" \
		"$agent_contract_file"
	require_literal "the positive ownership-verification procedure must remain" \
		"Verify a routine's creation record and current branch/worktree activity" \
		"$agent_contract_file"
	require_literal "external contributions must be reviewed statically" \
		"reviewed statically" "$agent_contract_file"
	require_literal "external code must never be checked out or executed" \
		"never checked out or executed" "$agent_contract_file"
	require_literal "an external merge must rest on a recorded CI evaluation" \
		"recorded evaluation of a CI run that exercised its change" \
		"$agent_contract_file"
	require_literal "self-promotion must remain readiness-gated" \
		"Self-promote only when" "$agent_contract_file"
	require_literal "the complete hygiene pentad must remain required" \
		"complete hygiene pentad" "$agent_contract_file"
	require_literal "threads and review-body findings must remain clear" \
		"zero unresolved threads and current review-body findings" \
		"$agent_contract_file"
	require_literal "conflicts and base lag must remain clear" \
		"no conflict or base lag" "$agent_contract_file"
	require_literal "the exact-head green review gate must name all three lanes" \
		"green exact-head review from CodeRabbit, Codex, or Cursor Bugbot" \
		"$agent_contract_file"
	require_literal "the local review round must stay a last resort" \
		"only when none of the three will deliver at that head may a clean local review round" \
		"$agent_contract_file"
	require_literal "an external pull request must never rest on a local review round" \
		"never for an external contributor's pull request" "$agent_contract_file"
	require_literal "promotion must bind the exact current head" \
		"exact current head" "$agent_contract_file"
	require_literal "promotion must require a real user-path evaluation" \
		"tried and evaluated through a real user path" "$agent_contract_file"
	require_literal "merges must pin the repository and the evaluated head" \
		"gh pr merge <number> --repo <owner>/<repo> --squash --match-head-commit <sha>" \
		"$agent_contract_file"
	require_literal "only CLEAN promoted PRs may merge" \
		"merge only a CLEAN" "$agent_contract_file"
	require_literal "agents must never arm auto-merge" \
		"Never use \`--auto\`" "$agent_contract_file"
	require_literal "the maintain skill must defer to AGENTS.md" \
		"AGENTS.md" "$skill_contract_file"
	require_literal "the maintain skill must name the canonical owner" \
		"That canonical section owns" "$skill_contract_file"
	require_literal "the maintain skill must prohibit local exceptions" \
		"do not invent local exceptions" "$skill_contract_file"

	for contract_file in "$agent_contract_file" "$skill_contract_file"; do
		forbid_literal "retired maintainer-promotion gate returned" \
			"maintainer promotion" "$contract_file"
		forbid_literal "branch/actor trust list returned" \
			"trust gate =" "$contract_file"
		forbid_pattern "dependency bot or branch shape returned as trust" \
			'trust gate[[:space:]]*[:=].*(dependabot|renovate|claude/)' \
			"$contract_file"
		forbid_literal "retired vague self-merge rule returned" \
			"self-merge your own unreviewed drafts" "$contract_file"
		forbid_literal "the maintain skill may not ignore AGENTS.md" \
			"Ignore AGENTS.md" "$contract_file"
		forbid_literal "the maintain skill may not override AGENTS.md" \
			"skill overrides" "$contract_file"
		forbid_literal "retired dependency-bot pull-request prohibition returned" \
			"do not review, rebase, adapt, promote, or merge them" "$contract_file"
		forbid_literal "retired external no-merge rule returned" \
			"promote them, or merge them" "$contract_file"
		forbid_literal "retired CodeRabbit pre-merge gate returned" \
			"supported CodeRabbit pre-merge check" "$contract_file"
		forbid_literal "retired two-lane review gate returned" \
			"exact-head CodeRabbit or Codex review" "$contract_file"
	done
}

# Each mutation below rewrites the copied files and must make validate_contract
# fail. A mutation whose target phrase no longer exists leaves the copy intact,
# validates clean, and fails this suite, so a stale mutation cannot pass silently.
# `+ 1` rather than ((n++)): under `set -e` the latter returns 1 on the increment
# from zero and would abort the suite on its very first mutation.
mutations_run=0

# Apply one sed expression to the copied AGENTS.md after normalising newlines,
# so a phrase that happens to wrap across lines is still mutated.
mutate_agents() {
	tr '\n' ' ' < "$mutation_dir/AGENTS.md" | sed "$1" > "$mutation_dir/AGENTS.tmp"
	mv "$mutation_dir/AGENTS.tmp" "$mutation_dir/AGENTS.md"
}

append_agents() {
	printf '\n%s\n' "$1" >> "$mutation_dir/AGENTS.md"
}

run_mutation() {
	mutations_run=$((mutations_run + 1))
	description=$1
	mutation=$2

	cp "$repo_root/AGENTS.md" "$mutation_dir/AGENTS.md"
	cp "$repo_root/.claude/skills/maintain/SKILL.md" "$mutation_dir/SKILL.md"

	case "$mutation" in
	drop-contract-deference)
		mutate_agents 's/this copy is stale: follow the monorepo contract/this copy wins/'
		;;
	remove-bot-boundary)
		mutate_agents 's/AUTOMATION-OWNED (NO-ACTION)/dependency update/'
		;;
	remove-dependabot-scope)
		mutate_agents 's/Renovate or Dependabot/Renovate/g'
		;;
	drop-bot-issue-boundary)
		mutate_agents 's/never select, edit, or close them/triage them freely/'
		;;
	drop-bot-progress-evidence)
		mutate_agents 's/only while live evidence shows it is still progressing them/indefinitely/'
		;;
	drop-bot-draft-fence)
		mutate_agents 's/convert the pull request to draft and disable auto-merge/push directly/'
		;;
	drop-bot-review-gate)
		mutate_agents 's/the adapted head then needs the normal exact-head review/the adapted head may merge at once/'
		;;
	restore-bot-pr-prohibition)
		append_agents 'Exact Renovate- and Dependabot-authored pull requests are **AUTOMATION-OWNED (NO-ACTION)**: do not review, rebase, adapt, promote, or merge them.'
		;;
	restore-human-gate)
		mutate_agents 's/Self-promote/wait for maintainer promotion/'
		;;
	trust-branch-shape)
		printf "\ntrust gate = \`devantler\`, \`dependabot[bot]\`, \`claude/*\`\n" \
			>> "$mutation_dir/AGENTS.md"
		;;
	remove-exact-head)
		mutate_agents 's/exact current head/branch head/g'
		;;
	remove-exact-head-review)
		mutate_agents 's/green exact-head review from CodeRabbit, Codex, or Cursor Bugbot/peer review/'
		;;
	restore-two-lane-review)
		append_agents 'Readiness also needs a green exact-head CodeRabbit or Codex review.'
		;;
	restore-premerge-gate)
		append_agents 'Readiness also needs a green supported CodeRabbit pre-merge check when that lane reviewed.'
		;;
	unguard-local-review)
		mutate_agents 's/only when none of the three will deliver at that head may/whenever convenient,/'
		;;
	local-review-for-external)
		mutate_agents "s/never for an external contributor's pull request/for any pull request/"
		;;
	remove-user-path)
		mutate_agents 's/must also be tried/must only be reviewed/'
		;;
	remove-ownership-procedure)
		mutate_agents "s/routine's creation record/optional routine record/g"
		;;
	drop-external-static-review)
		mutate_agents 's/reviewed statically/merged on trust/'
		;;
	weaken-external-execution)
		mutate_agents 's/never checked out or executed/checked out when needed/'
		;;
	drop-external-ci-evaluation)
		mutate_agents 's/recorded evaluation of a CI run that exercised its change/quick look at CI/'
		;;
	restore-external-no-merge)
		append_agents 'External-contributor pull requests are **static-review-only** — never check out or execute their code, push to them, promote them, or merge them.'
		;;
	restore-bare-merge)
		mutate_agents 's|gh pr merge <number> --repo <owner>/<repo> --squash --match-head-commit <sha>|gh pr merge <number> --squash|'
		;;
	override-canonical-agents)
		sed 's/That canonical section owns/Ignore AGENTS.md; this skill overrides/' \
			"$mutation_dir/SKILL.md" > "$mutation_dir/SKILL.tmp"
		mv "$mutation_dir/SKILL.tmp" "$mutation_dir/SKILL.md"
		;;
	*) fail "unknown mutation: $mutation" ;;
	esac

	if (validate_contract "$mutation_dir/AGENTS.md" "$mutation_dir/SKILL.md") \
		>/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 3 ] || fail "usage: $0 --validate <AGENTS.md> <SKILL.md>"
	validate_contract "$2" "$3"
	exit 0
fi

validate_contract \
	"$repo_root/AGENTS.md" \
	"$repo_root/.claude/skills/maintain/SKILL.md"

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT

run_mutation "monorepo-contract deference removed" drop-contract-deference
run_mutation "dependency-bot issue no-action removed" remove-bot-boundary
run_mutation "Dependabot removed from no-action scope" remove-dependabot-scope
run_mutation "dependency-bot issues opened to agent edits" drop-bot-issue-boundary
run_mutation "dependency-bot PRs left alone without evidence" drop-bot-progress-evidence
run_mutation "bot-branch adaptation without the draft fence" drop-bot-draft-fence
run_mutation "adapted bot head merged without review" drop-bot-review-gate
run_mutation "retired dependency-bot PR prohibition restored" restore-bot-pr-prohibition
run_mutation "retired human-promotion gate restored" restore-human-gate
run_mutation "branch and actor shape treated as trust" trust-branch-shape
run_mutation "exact-head readiness removed" remove-exact-head
run_mutation "exact-head review gate removed" remove-exact-head-review
run_mutation "retired two-lane review gate restored" restore-two-lane-review
run_mutation "retired CodeRabbit pre-merge gate restored" restore-premerge-gate
run_mutation "local review round no longer a last resort" unguard-local-review
run_mutation "local review round allowed on external PRs" local-review-for-external
run_mutation "user-path evaluation removed" remove-user-path
run_mutation "positive ownership procedure removed" remove-ownership-procedure
run_mutation "external static review removed" drop-external-static-review
run_mutation "external branch execution allowed" weaken-external-execution
run_mutation "external merge without a recorded CI evaluation" drop-external-ci-evaluation
run_mutation "retired external no-merge rule restored" restore-external-no-merge
run_mutation "bare unpinned merge restored" restore-bare-merge
run_mutation "maintain skill overrides AGENTS.md" override-canonical-agents

echo "PASS: scaffolded agent contract (happy path + ${mutations_run} safety mutations)"
