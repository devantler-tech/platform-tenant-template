#!/usr/bin/env sh
# Pin the delivery inputs that every adopted tenant's default PR gate validates.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
ci_workflow=$repo_root/.github/workflows/ci.yaml
scaffold_workflow=$repo_root/.github/workflows/validate-scaffold.yaml
readme=$repo_root/README.md
agents=$repo_root/AGENTS.md
template_sync_ignore=$repo_root/.templatesyncignore

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

validate_contract() {
	ci_file=$1
	scaffold_file=$2
	readme_file=$3
	agents_file=$4
	ignore_file=$5

	assert_ci() {
		description=$1
		expression=$2
		if ! yq eval -e "$expression" "$ci_file" >/dev/null 2>&1; then
			fail "default CI contract: $description"
		fi
	}

	assert_ci "workflow must run on every pull request to main" '
		((.on | keys | sort | join(",")) == "pull_request")
		and ((.on.pull_request | keys | sort | join(",")) == "branches")
		and ((.on.pull_request.branches | join(",")) == "main")
	'
	assert_ci "workflow permissions must default to none" \
		'(has("permissions")) and ((.permissions | type) == "!!map") and ((.permissions | length) == 0)'
	assert_ci "workflow must not expose inherited environment values" \
		'(has("env") | not)'
	assert_ci "delivery job must retain its stable identity" \
		'.jobs."delivery-inputs".name == "Delivery inputs"'
	assert_ci "delivery job must have only audited keys" \
		'(.jobs."delivery-inputs" | keys | sort | join(",")) == "name,permissions,runs-on,steps"'
	assert_ci "delivery job must use the hosted runner" \
		'.jobs."delivery-inputs"."runs-on" == "ubuntu-latest"'
	assert_ci "delivery job must be unconditional" \
		'(.jobs."delivery-inputs" | has("if") | not)'
	assert_ci "delivery job must have no dependencies" \
		'(.jobs."delivery-inputs" | has("needs") | not)'
	assert_ci "delivery job must fail closed" \
		'(.jobs."delivery-inputs" | has("continue-on-error") | not)'
	assert_ci "delivery job must not access an environment" \
		'(.jobs."delivery-inputs" | has("environment") | not)'
	assert_ci "delivery job must not set an environment" \
		'(.jobs."delivery-inputs" | has("env") | not)'
	assert_ci "delivery job must contain exactly the audited steps" \
		'(.jobs."delivery-inputs".steps | length) == 4'
	assert_ci "delivery steps must not set an environment" '
		[.jobs."delivery-inputs".steps[] | select(has("env"))]
		| length == 0
	'
	assert_ci "delivery job must not reference repository secrets" '
		(.jobs."delivery-inputs" | to_json | contains("secrets") | not)
	'
	assert_ci "runner-hardening step must have only audited keys" '
		((.jobs."delivery-inputs".steps[0] | keys | sort | join(",")) == "name,uses,with")
		and ((.jobs."delivery-inputs".steps[0].with | keys | sort | join(",")) == "egress-policy")
		and (.jobs."delivery-inputs".steps[0].uses | test("^step-security/harden-runner@[0-9a-f]{40}$"))
		and (.jobs."delivery-inputs".steps[0].with."egress-policy" == "audit")
	'
	assert_ci "checkout step must have only audited keys" '
		((.jobs."delivery-inputs".steps[1] | keys | sort | join(",")) == "name,uses,with")
		and ((.jobs."delivery-inputs".steps[1].with | keys | sort | join(",")) == "persist-credentials")
		and (.jobs."delivery-inputs".steps[1].uses | test("^actions/checkout@[0-9a-f]{40}$"))
		and (.jobs."delivery-inputs".steps[1].with."persist-credentials" == false)
	'
	assert_ci "image-build step must have only audited keys" '
		((.jobs."delivery-inputs".steps[2] | keys | sort | join(",")) == "name,run,shell,working-directory")
		and (.jobs."delivery-inputs".steps[2].run == "docker build --tag tenant-delivery-check .")
		and (.jobs."delivery-inputs".steps[2].shell == "bash")
		and (.jobs."delivery-inputs".steps[2]."working-directory" == ".")
	'
	assert_ci "manifest-render step must have only audited keys" '
		((.jobs."delivery-inputs".steps[3] | keys | sort | join(",")) == "name,run,shell,working-directory")
		and (.jobs."delivery-inputs".steps[3].run == "kubectl kustomize deploy/ >/dev/null")
		and (.jobs."delivery-inputs".steps[3].shell == "bash")
		and (.jobs."delivery-inputs".steps[3]."working-directory" == ".")
	'
	assert_ci "delivery job must have one permission" \
		'(.jobs."delivery-inputs".permissions | length) == 1'
	assert_ci "delivery job must have contents-read only" \
		'.jobs."delivery-inputs".permissions.contents == "read"'
	assert_ci "delivery steps must fail closed" '
		[.jobs."delivery-inputs".steps[]
		| select(has("if") or has("continue-on-error"))]
		| length == 0
	'
	assert_ci "runner hardening must stay pinned" '
		[.jobs."delivery-inputs".steps[] | select(
			(.uses | test("^step-security/harden-runner@[0-9a-f]{40}$"))
			and .with."egress-policy" == "audit"
		)] | length == 1
	'
	assert_ci "delivery job must have exactly one checkout" '
		[.jobs."delivery-inputs".steps[] | select(
			(.uses // "") | test("^actions/checkout@")
		)] | length == 1
	'
	assert_ci "checkout must stay pinned and credential-free" '
		[.jobs."delivery-inputs".steps[] | select(
			(.uses | test("^actions/checkout@[0-9a-f]{40}$"))
			and .with."persist-credentials" == false
		)] | length == 1
	'
	assert_ci "tenant image build is missing" '
		[.jobs."delivery-inputs".steps[] | select(
			(.run // "") == "docker build --tag tenant-delivery-check ."
		)] | length == 1
	'
	assert_ci "tenant manifest render is missing" '
		[.jobs."delivery-inputs".steps[] | select(
			(.run // "") == "kubectl kustomize deploy/ >/dev/null"
		)] | length == 1
	'
	assert_ci "required-check aggregate must depend on both jobs exactly" \
		'(.jobs."ci-required-checks".needs | join(",")) == "example,delivery-inputs"'
	# shellcheck disable=SC2016
	assert_ci "required-check aggregate must run after every result" \
		'.jobs."ci-required-checks".if == "${{ always() }}"'
	assert_ci "required-check aggregate must fail closed" \
		'(.jobs."ci-required-checks" | has("continue-on-error") | not)'
	assert_ci "required-check job must have only audited keys" \
		'(.jobs."ci-required-checks" | keys | sort | join(",")) == "if,name,needs,permissions,runs-on,steps"'
	assert_ci "required-check job must have no permissions" \
		'((.jobs."ci-required-checks".permissions | type) == "!!map") and ((.jobs."ci-required-checks".permissions | length) == 0)'
	assert_ci "required-check job must contain exactly two audited steps" \
		'(.jobs."ci-required-checks".steps | length) == 2'
	# The shared aggregator intentionally tolerates skipped jobs, so the tenant
	# gate must reject every non-success result before invoking it.
	# shellcheck disable=SC2016
	assert_ci "required-check aggregate must reject non-success results" '
		[.jobs."ci-required-checks".steps[] | select(
			.name == "Reject incomplete CI jobs"
			and .if == "${{ needs.example.result != '\''success'\'' || needs.delivery-inputs.result != '\''success'\'' }}"
			and .run == "exit 1"
			and .shell == "bash"
			and ((keys | sort | join(",")) == "if,name,run,shell")
		)] | length == 1
	'
	# shellcheck disable=SC2016
	assert_ci "required-check aggregate must consume the exact results" '
		[.jobs."ci-required-checks".steps[] | select(
			(.uses | test("^devantler-tech/actions/aggregate-job-checks@[0-9a-f]{40}$"))
			and .with."job-results" == "${{ needs.example.result }} ${{ needs.delivery-inputs.result }}"
			and ((keys | sort | join(",")) == "name,uses,with")
			and ((.with | keys | sort | join(",")) == "job-results")
		)] | length == 1
	'

	# shellcheck disable=SC2016
	if ! yq eval -e '
		.jobs."validate-scaffold".steps
		| map(select(
			(.run // "") == "sh scripts/tenant-ci-contract.test.sh"
			and ((has("if") or has("continue-on-error")) | not)
		))
		| length == 1
	' "$scaffold_file" >/dev/null; then
		fail "template validation does not exercise the tenant CI contract"
	fi

	# Backticks are documentation literals, never shell expressions.
	# shellcheck disable=SC2016
	grep -Fq 'Default PR CI always builds the tenant image and renders `deploy/`' \
		"$readme_file" || fail "README omits the delivery-input invariant"
	grep -Fq 'sh scripts/tenant-ci-contract.test.sh' "$readme_file" ||
		fail "README local validation omits the tenant CI contract"
	# shellcheck disable=SC2016
	tr '\n' ' ' < "$agents_file" |
		grep -Fq 'build the tenant image and render `deploy/` before merge' ||
		fail "scaffolded validation guidance omits the delivery-input invariant"
	grep -Fxq 'scripts/tenant-ci-contract.test.sh' "$ignore_file" ||
		fail ".templatesyncignore lacks the scaffold-only tenant CI contract"
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 6 ] ||
		fail "usage: $0 --validate <ci> <scaffold> <README> <AGENTS> <templatesyncignore>"
	validate_contract "$2" "$3" "$4" "$5" "$6"
	exit 0
fi

validate_contract \
	"$ci_workflow" \
	"$scaffold_workflow" \
	"$readme" \
	"$agents" \
	"$template_sync_ignore"

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT

run_mutation() {
	description=$1
	ci_mutation=${2:-}
	scaffold_mutation=${3:-}
	readme_mutation=${4:-}
	agents_mutation=${5:-}
	ignore_mutation=${6:-}

	cp "$ci_workflow" "$mutation_dir/ci.yaml"
	cp "$scaffold_workflow" "$mutation_dir/scaffold.yaml"
	cp "$readme" "$mutation_dir/README.md"
	cp "$agents" "$mutation_dir/AGENTS.md"
	cp "$template_sync_ignore" "$mutation_dir/templatesyncignore"

	if [ -n "$ci_mutation" ]; then
		yq eval "$ci_mutation" "$mutation_dir/ci.yaml" > "$mutation_dir/mutant.yaml"
		mv "$mutation_dir/mutant.yaml" "$mutation_dir/ci.yaml"
	fi
	if [ -n "$scaffold_mutation" ]; then
		yq eval "$scaffold_mutation" "$mutation_dir/scaffold.yaml" > "$mutation_dir/mutant.yaml"
		mv "$mutation_dir/mutant.yaml" "$mutation_dir/scaffold.yaml"
	fi
	if [ -n "$readme_mutation" ]; then
		sed "$readme_mutation" "$mutation_dir/README.md" > "$mutation_dir/mutant.md"
		mv "$mutation_dir/mutant.md" "$mutation_dir/README.md"
	fi
	if [ -n "$agents_mutation" ]; then
		sed "$agents_mutation" "$mutation_dir/AGENTS.md" > "$mutation_dir/mutant.md"
		mv "$mutation_dir/mutant.md" "$mutation_dir/AGENTS.md"
	fi
	if [ -n "$ignore_mutation" ]; then
		sed "$ignore_mutation" "$mutation_dir/templatesyncignore" > "$mutation_dir/mutant.ignore"
		mv "$mutation_dir/mutant.ignore" "$mutation_dir/templatesyncignore"
	fi

	if (validate_contract \
		"$mutation_dir/ci.yaml" \
		"$mutation_dir/scaffold.yaml" \
		"$mutation_dir/README.md" \
		"$mutation_dir/AGENTS.md" \
		"$mutation_dir/templatesyncignore") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_mutation "delivery job removed" \
	'del(.jobs."delivery-inputs")'
run_mutation "pull-request trigger removed" \
	'del(.on.pull_request)'
run_mutation "pull-request target replaced" \
	'.on.pull_request.branches = ["develop"]'
run_mutation "pull-request paths narrowed" \
	'.on.pull_request.paths = ["src/**"]'
run_mutation "pull-request paths ignored" \
	'.on.pull_request."paths-ignore" = ["deploy/**"]'
run_mutation "workflow permissions default removed" \
	'del(.permissions)'
# shellcheck disable=SC2016
run_mutation "workflow secret environment added" \
	'.env.TOKEN = "${{ secrets.APP_PRIVATE_KEY }}"'
run_mutation "container build removed" \
	'del(.jobs."delivery-inputs".steps[] | select((.run // "") == "docker build --tag tenant-delivery-check ."))'
run_mutation "manifest render removed" \
	'del(.jobs."delivery-inputs".steps[] | select((.run // "") == "kubectl kustomize deploy/ >/dev/null"))'
run_mutation "checkout credentials retained" \
	'.jobs."delivery-inputs".steps[] |= (select(.uses | test("^actions/checkout@[0-9a-f]{40}$")).with."persist-credentials" = true)'
run_mutation "second mutable checkout added" \
	'.jobs."delivery-inputs".steps += [{"name": "Unsafe checkout", "uses": "actions/checkout@main"}]'
run_mutation "checkout moved before runner hardening" \
	'.jobs."delivery-inputs".steps[0] = {"name": "Checkout first", "uses": "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0", "with": {"persist-credentials": false}} |
	 .jobs."delivery-inputs".steps[1] = {"name": "Harden too late", "uses": "step-security/harden-runner@bf7454d06d71f1098171f2acdf0cd4708d7b5920", "with": {"egress-policy": "audit"}}'
run_mutation "extra action added" \
	'.jobs."delivery-inputs".steps += [{"name": "Extra action", "uses": "example/action@0123456789abcdef0123456789abcdef01234567"}]'
# shellcheck disable=SC2016
run_mutation "secret environment added" \
	'.jobs."delivery-inputs".steps[2].env.TOKEN = "${{ secrets.APP_PRIVATE_KEY }}"'
# shellcheck disable=SC2016
run_mutation "secret action input added" \
	'.jobs."delivery-inputs".steps[1].with.token = "${{ secrets.APP_PRIVATE_KEY }}"'
# shellcheck disable=SC2016
run_mutation "bracket secret action input added" \
	'.jobs."delivery-inputs".steps[1].with.token = "${{ secrets['\''APP_PRIVATE_KEY'\''] }}"'
run_mutation "delivery job no-op shell default added" \
	'.jobs."delivery-inputs".defaults.run.shell = "echo {0}"'
run_mutation "image build shell replaced with no-op" \
	'.jobs."delivery-inputs".steps[2].shell = "echo {0}"'
run_mutation "manifest render redirected to decoy" \
	'.jobs."delivery-inputs".steps[3]."working-directory" = "fixtures/valid"'
run_mutation "job permissions broadened" \
	'.jobs."delivery-inputs".permissions.packages = "write"'
run_mutation "delivery dependency removed from aggregate" \
	'.jobs."ci-required-checks".needs = ["example"]'
run_mutation "delivery dependency replaced with duplicate" \
	'.jobs."ci-required-checks".needs = ["example", "example"]'
# The GitHub expression is mutation data, not a shell expansion.
# shellcheck disable=SC2016
run_mutation "delivery result removed from aggregate" \
	'.jobs."ci-required-checks".steps[0].with."job-results" = "${{ needs.example.result }}"'
# shellcheck disable=SC2016
run_mutation "delivery results coerced before aggregation" \
	'.jobs."ci-required-checks".steps[0].with."job-results" = "${{ needs.example.result == '\''success'\'' }} ${{ needs.delivery-inputs.result == '\''success'\'' }}"'
run_mutation "aggregate action allowed to fail" \
	'.jobs."ci-required-checks".steps[0]."continue-on-error" = true'
run_mutation "required-check no-op shell default added" \
	'.jobs."ci-required-checks".defaults.run.shell = "echo {0}"'
run_mutation "required-check permissions broadened" \
	'.jobs."ci-required-checks".permissions.contents = "write"'
run_mutation "non-success result guard removed" \
	'del(.jobs."ci-required-checks".steps[] | select(.name == "Reject incomplete CI jobs"))'
run_mutation "non-success result guard allowed to fail" \
	'.jobs."ci-required-checks".steps[] |= (select(.name == "Reject incomplete CI jobs")."continue-on-error" = true)'
run_mutation "delivery job made conditional" \
	'.jobs."delivery-inputs".if = "github.actor == '\''devantler'\''"'
run_mutation "contract invocation removed" '' \
	'del(.jobs."validate-scaffold".steps[] | select((.run // "") == "sh scripts/tenant-ci-contract.test.sh"))'
run_mutation "README invariant removed" '' '' \
	'/Default PR CI always builds the tenant image/d'
run_mutation "README local validation command removed" '' '' \
	'/sh scripts\/tenant-ci-contract.test.sh/d'
run_mutation "scaffolded validation invariant removed" '' '' '' \
	'/build the tenant image/d'
run_mutation "contract ignore removed" '' '' '' '' \
	'/^scripts\/tenant-ci-contract\.test\.sh$/d'

echo "PASS: tenant CI contract (happy path + 35 safety mutations)"
