#!/usr/bin/env sh
# Verify that a fresh tenant starts at or above Platform's generated VPA CPU floor.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")

# Report a VPA-floor contract violation and stop the current validation path.
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# Parse a positive canonical millicore quantity and print its numeric value.
millicores() {
	cpu_quantity=$1
	case "$cpu_quantity" in
		*m)
			cpu_number=${cpu_quantity%m}
			case "$cpu_number" in
				'' | *[!0-9]*) fail "CPU quantity must use positive canonical millicores: $cpu_quantity" ;;
			esac
		[ "$cpu_number" -gt 0 ] || fail "CPU quantity must be positive: $cpu_quantity"
		printf '%s\n' "$cpu_number"
		;;
	*) fail "CPU quantity must use canonical millicores: $cpu_quantity" ;;
	esac
}

# Derive Platform's unique Deployment VPA floor and enforce it on the scaffold.
validate_vpa_floor() (
	platform_root=$1
	scaffold_root=$2
	platform_policy=$platform_root/k8s/bases/infrastructure/cluster-policies/best-practices/auto-vpa-deployment.yaml
	deployment=$scaffold_root/deploy/deployment.yaml

	[ -f "$platform_policy" ] || fail "Platform auto-vpa policy is missing: $platform_policy"
	[ -f "$deployment" ] || fail "scaffold Deployment is missing: $deployment"

	# Evaluate CEL with Kyverno itself rather than parsing the expression as text.
	# A single canonical policy must generate one VPA for this actual scaffold.
	yq eval -e '
		.apiVersion == "policies.kyverno.io/v1"
		and .kind == "GeneratingPolicy"
		and .metadata.name == "auto-vpa-deployment"
		and (.spec.generate | length) == 1
	' "$platform_policy" >/dev/null || fail "expected the canonical Deployment GeneratingPolicy"
	validation_dir=$(mktemp -d)
	trap 'rm -rf "$validation_dir"' EXIT
	yq eval '.metadata.namespace = "vpa-floor-check"' "$deployment" > "$validation_dir/deployment.yaml" ||
		fail "could not prepare the scaffold Deployment"
	cat > "$validation_dir/values.yaml" <<'VALUES'
apiVersion: cli.kyverno.io/v1alpha1
kind: Values
namespaceSelector:
  - name: vpa-floor-check
    labels:
      kubernetes.io/metadata.name: vpa-floor-check
VALUES
	"${KYVERNO_CLI:-kyverno}" apply "$platform_policy" \
		--resource "$validation_dir/deployment.yaml" \
		--values-file "$validation_dir/values.yaml" \
		--output "$validation_dir/generated.yaml" --warn-exit-code 0 \
		> "$validation_dir/kyverno.log" 2>&1 || {
		cat "$validation_dir/kyverno.log" >&2
		fail "Kyverno could not evaluate Platform's Deployment VPA policy"
	}
	[ -s "$validation_dir/generated.yaml" ] || fail "Platform generated no VPA for the scaffold"
	yq eval-all -o=json -I=0 'select(. != null)' \
		"$validation_dir/generated.yaml" > "$validation_dir/generated-stream.json" ||
		fail "could not read the generated VPA documents"
	jq -s . "$validation_dir/generated-stream.json" > "$validation_dir/generated.json" ||
		fail "could not read the generated VPA JSON"
	workload_name=$(yq eval -r '.metadata.name' "$deployment") || fail "could not read the scaffold identity"
	jq -e --arg workload "$workload_name" '
		length == 1
		and .[0].apiVersion == "autoscaling.k8s.io/v1"
		and .[0].kind == "VerticalPodAutoscaler"
		and .[0].metadata.namespace == "vpa-floor-check"
		and .[0].spec.targetRef == {apiVersion: "apps/v1", kind: "Deployment", name: $workload}
		and (.[0].spec.resourcePolicy.containerPolicies | length) == 1
		and .[0].spec.resourcePolicy.containerPolicies[0].containerName == "*"
	' "$validation_dir/generated.json" >/dev/null ||
		fail "expected exactly one generated VPA and wildcard CPU floor for the scaffold Deployment"
	platform_floors=$(jq -r '.[0].spec.resourcePolicy.containerPolicies[0].minAllowed.cpu' \
		"$validation_dir/generated.json")
	platform_floor_m=$(millicores "$platform_floors")

	# shellcheck disable=SC2016
	scaffold_requests=$(yq eval -r '
		select(.apiVersion == "apps/v1" and .kind == "Deployment")
		| .metadata.name as $workload_name
		| .spec.template.spec.containers[]
		| select(.name == $workload_name)
		| .resources.requests.cpu
	' "$deployment")
	scaffold_request_count=$(printf '%s\n' "$scaffold_requests" | awk 'NF { count++ } END { print count + 0 }')
	[ "$scaffold_request_count" -eq 1 ] ||
		fail "expected exactly one scaffold application CPU request, found $scaffold_request_count"
	scaffold_request_m=$(millicores "$scaffold_requests")

	[ "$scaffold_request_m" -ge "$platform_floor_m" ] ||
		fail "scaffold CPU request ${scaffold_requests} is below Platform VPA floor ${platform_floors}; raise deploy/deployment.yaml"

	printf 'Platform VPA floor contract: request=%s floor=%s\n' "$scaffold_requests" "$platform_floors"
)

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 3 ] || fail "usage: $0 --validate <platform-root> <scaffold-root>"
	validate_vpa_floor "$2" "$3"
	exit 0
fi

platform_root=${PLATFORM_ROOT:-$repo_root/.platform}
validate_vpa_floor "$platform_root" "$repo_root"

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT

platform_policy_rel=k8s/bases/infrastructure/cluster-policies/best-practices/auto-vpa-deployment.yaml
mkdir -p "$mutation_dir/platform/$(dirname -- "$platform_policy_rel")" "$mutation_dir/scaffold/deploy"
cp "$platform_root/$platform_policy_rel" "$mutation_dir/platform/$platform_policy_rel"
cp "$repo_root/deploy/deployment.yaml" "$mutation_dir/scaffold/deploy/deployment.yaml"

# Rebuild pristine fixtures, apply one mutation, and require validation to reject it.
run_mutation() {
	description=$1
	platform_mutation=$2
	scaffold_mutation=$3

	cp "$platform_root/$platform_policy_rel" "$mutation_dir/platform/$platform_policy_rel"
	cp "$repo_root/deploy/deployment.yaml" "$mutation_dir/scaffold/deploy/deployment.yaml"

	if [ -n "$platform_mutation" ]; then
		yq eval "$platform_mutation" "$mutation_dir/platform/$platform_policy_rel" > "$mutation_dir/platform-mutant.yaml"
		mv "$mutation_dir/platform-mutant.yaml" "$mutation_dir/platform/$platform_policy_rel"
	fi
	if [ -n "$scaffold_mutation" ]; then
		yq eval "$scaffold_mutation" "$mutation_dir/scaffold/deploy/deployment.yaml" > "$mutation_dir/scaffold-mutant.yaml"
		mv "$mutation_dir/scaffold-mutant.yaml" "$mutation_dir/scaffold/deploy/deployment.yaml"
	fi

	if (validate_vpa_floor "$mutation_dir/platform" "$mutation_dir/scaffold") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_mutation "scaffold request lowered below the Platform floor" '' \
	'.spec.template.spec.containers[0].resources.requests.cpu = "10m"'
run_mutation "Platform Deployment VPA rule removed" \
	'.spec.generate = []' ''
run_mutation "Platform floor raised above the scaffold request" \
	'.spec.generate[0].expression |= sub("\"cpu\": \"[^\"]+\""; "\"cpu\": \"60m\"")' ''
run_mutation "Platform Deployment VPA rule duplicated" \
	'.spec.generate += [.spec.generate[0]]' ''
run_mutation "Platform Deployment VPA policy renamed" \
	'.metadata.name = "duplicate-vpa-for-deployment"' ''
run_mutation "Platform CPU floor removed" \
	'.spec.generate[0].expression |= sub("\"cpu\": \"[^\"]+\", "; "")' ''
run_mutation "Platform CPU floor changed to a noncanonical quantity" \
	'.spec.generate[0].expression |= sub("\"cpu\": \"[^\"]+\""; "\"cpu\": \"0.05\"")' ''
run_mutation "scaffold application container duplicated" '' \
	'.spec.template.spec.containers += [.spec.template.spec.containers[0]]'
run_mutation "Platform policy matches no Deployment" \
	'.spec.matchConstraints.resourceRules[0].resources = ["statefulsets"]' ''
run_mutation "Platform generates a VPA for the wrong workload kind" \
	'.spec.generate[0].expression |= sub("\"kind\": \"Deployment\""; "\"kind\": \"StatefulSet\"")' ''

echo "PASS: Platform VPA floor contract (happy path + 10 safety mutations)"
