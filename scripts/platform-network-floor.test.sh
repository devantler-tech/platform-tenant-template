#!/usr/bin/env sh
# Verify that Platform's generated namespace network floor remains compatible
# with the required day-one paths in this template's CiliumNetworkPolicy.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# Bind the scaffold's two default hostnames to Platform's live local and
# production domains. Custom domains are added after adoption; the template
# baseline deliberately starts with exactly these two paved-road values.
validate_platform_route_hostnames() {
	platform_checkout=$1
	http_route=$2
	local_values=$platform_checkout/k8s/clusters/local/bootstrap/config-map.yaml
	prod_values=$platform_checkout/k8s/clusters/prod/bootstrap/config-map.yaml

	[ -f "$local_values" ] || fail "Platform local domain source is missing: $local_values"
	[ -f "$prod_values" ] || fail "Platform production domain source is missing: $prod_values"

	for cluster_domain_pair in "local:$local_values" "prod:$prod_values"; do
		cluster_name=${cluster_domain_pair%%:*}
		values_file=${cluster_domain_pair#*:}
		export cluster_name
		yq eval -e '
			.kind == "ConfigMap"
			and .metadata.name == "variables-cluster"
			and .metadata.namespace == "flux-system"
			and .data.cluster_name == strenv(cluster_name)
			and (.data.domain | test("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$"))
		' "$values_file" >/dev/null ||
			fail "Platform $cluster_name domain source is incomplete"
	done

	local_domain=$(yq eval -r '.data.domain' "$local_values")
	prod_domain=$(yq eval -r '.data.domain' "$prod_values")
	[ "$local_domain" != "$prod_domain" ] ||
		fail "Platform local and production domains must remain distinct"
	export local_domain prod_domain

	yq eval -e '
		.kind == "HTTPRoute"
		and .metadata.name == "app"
		and (.spec.hostnames | length) == 2
		and (.spec.hostnames | contains(["app." + strenv(local_domain)]))
		and (.spec.hostnames | contains(["app." + strenv(prod_domain)]))
	' "$http_route" >/dev/null ||
		fail "rendered tenant HTTPRoute no longer carries both live Platform domains"
}

validate_network_floor() {
	platform_policy=$1
	scaffold_policy=$2
	service=$3
	deployment=$4
	http_route=$5

	[ -f "$platform_policy" ] ||
		fail "Platform add-default-deny policy is missing: $platform_policy"
	[ -f "$scaffold_policy" ] ||
		fail "tenant scaffold network policy is missing: $scaffold_policy"
	[ -f "$service" ] || fail "rendered tenant Service is missing: $service"
	[ -f "$deployment" ] || fail "rendered tenant Deployment is missing: $deployment"
	[ -f "$http_route" ] || fail "rendered tenant HTTPRoute is missing: $http_route"

	# Cilium's CRD requires at least one policy direction to be present, so the
	# generated default-deny carries empty ingress/egress allow lists and relies on
	# enableDefaultDeny to activate isolation. Empty lists select no traffic, so the
	# namespace stays fail-closed and the tenant allow policy remains the only thing
	# that opens it. An ingressDeny/egressDeny entry would take precedence over that
	# allow policy, and a non-empty ingress/egress would widen the floor, so reject
	# both drifts explicitly.
	# Keep independent assertions in an array. yq's boolean operator changes the
	# input context of its right-hand expression, which can hide missing fields.
	# shellcheck disable=SC2016
	yq eval -e '
		[
			.kind == "ClusterPolicy",
			.metadata.name == "add-default-deny",
			(.spec.applyRules // "All") == "All",
			([.spec.rules[] | select(.name == "generate-default-deny")] | length) == 1,
			([.spec.rules[] | select(.name == "generate-allow-dns")] | length) == 1,
			([.spec.rules[] | select(.name == "generate-default-deny-networkpolicy")] | length) == 1,
			([.spec.rules[] | select([
				.generate.kind == "CiliumNetworkPolicy",
				.generate.kind == "NetworkPolicy"
			] | any)] | length) == 3
		] | all
	' "$platform_policy" >/dev/null ||
		fail "Platform generated network floor no longer has all three required rules"
	# shellcheck disable=SC2016
	yq eval -e '
		.spec.rules[] | select(.name == "generate-default-deny") | [
			(has("preconditions") | not),
			(.match | keys | length) == 1,
			(.match.any | length) == 1,
			(.match.any[0].resources | keys | length) == 1,
			(.match.any[0].resources.kinds | [(length == 1), contains(["Namespace"])] | all),
			(.exclude | keys | length) == 1,
			(.exclude.any | length) == 1,
			(.exclude.any[0].resources | keys | length) == 1,
			(.exclude.any[0].resources.names | [(length == 3), contains(["kube-node-lease"]), contains(["kube-public"]), contains(["kube-system"])] | all),
			.generate.generateExisting == true,
			.generate.apiVersion == "cilium.io/v2",
			.generate.kind == "CiliumNetworkPolicy",
			.generate.name == "default-deny",
			.generate.namespace == "{{request.object.metadata.name}}",
			.generate.synchronize == true,
			(.generate.data.spec | keys | length) == 4,
			(.generate.data.spec.endpointSelector | keys | length) == 0,
			.generate.data.spec.enableDefaultDeny.ingress == true,
			.generate.data.spec.enableDefaultDeny.egress == true,
			(.generate.data.spec | has("ingress")),
			(.generate.data.spec.ingress | tag) == "!!seq",
			(.generate.data.spec.ingress | length) == 0,
			(.generate.data.spec | has("egress")),
			(.generate.data.spec.egress | tag) == "!!seq",
			(.generate.data.spec.egress | length) == 0,
			(.generate.data.spec | has("ingressDeny") | not),
			(.generate.data.spec | has("egressDeny") | not)
		] | all
	' "$platform_policy" >/dev/null ||
		fail "Platform generated Cilium default-deny gained a traffic matcher or lost its fail-closed shape"
	# shellcheck disable=SC2016
	yq eval -e '
		.spec.rules[] | select(.name == "generate-allow-dns") | [
			(has("preconditions") | not),
			(.match | keys | length) == 1,
			(.match.any | length) == 1,
			(.match.any[0].resources | keys | length) == 1,
			(.match.any[0].resources.kinds | [(length == 1), contains(["Namespace"])] | all),
			(.exclude | keys | length) == 1,
			(.exclude.any | length) == 1,
			(.exclude.any[0].resources | keys | length) == 1,
			(.exclude.any[0].resources.names | [(length == 3), contains(["kube-node-lease"]), contains(["kube-public"]), contains(["kube-system"])] | all),
			.generate.generateExisting == true,
			.generate.apiVersion == "cilium.io/v2",
			.generate.kind == "CiliumNetworkPolicy",
			.generate.name == "allow-dns",
			.generate.namespace == "{{request.object.metadata.name}}",
			.generate.synchronize == true,
			(.generate.data.spec | keys | length) == 2,
			(.generate.data.spec.endpointSelector | keys | length) == 0,
			(.generate.data.spec | has("ingressDeny") | not),
			(.generate.data.spec | has("egressDeny") | not),
			(.generate.data.spec.egress | length) == 1,
			(.generate.data.spec.egress[0] | keys | length) == 2,
			(.generate.data.spec.egress[0].toEndpoints | length) == 1,
			(.generate.data.spec.egress[0].toEndpoints[0] | keys | length) == 1,
			(.generate.data.spec.egress[0].toEndpoints[0].matchLabels | keys | length) == 2,
			.generate.data.spec.egress[0].toEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "kube-system",
			.generate.data.spec.egress[0].toEndpoints[0].matchLabels."k8s-app" == "kube-dns",
			(.generate.data.spec.egress[0].toPorts | length) == 1,
			(.generate.data.spec.egress[0].toPorts[0] | keys | length) == 1,
			(.generate.data.spec.egress[0].toPorts[0].ports | [(length == 2), contains([{"port": "53", "protocol": "TCP"}]), contains([{"port": "53", "protocol": "UDP"}])] | all)
		] | all
	' "$platform_policy" >/dev/null ||
		fail "Platform generated DNS allowance no longer covers kube-dns over TCP and UDP"
	# shellcheck disable=SC2016
	yq eval -e '
		.spec.rules[] | select(.name == "generate-default-deny-networkpolicy") | [
			(has("preconditions") | not),
			(.match | keys | length) == 1,
			(.match.any | length) == 1,
			(.match.any[0].resources | keys | length) == 1,
			(.match.any[0].resources.kinds | [(length == 1), contains(["Namespace"])] | all),
			(.exclude | keys | length) == 1,
			(.exclude.any | length) == 1,
			(.exclude.any[0].resources | keys | length) == 1,
			(.exclude.any[0].resources.names | [(length == 3), contains(["kube-node-lease"]), contains(["kube-public"]), contains(["kube-system"])] | all),
			.generate.generateExisting == true,
			.generate.apiVersion == "networking.k8s.io/v1",
			.generate.kind == "NetworkPolicy",
			.generate.name == "default-deny",
			.generate.namespace == "{{request.object.metadata.name}}",
			.generate.synchronize == true,
			(.generate.data.spec.podSelector | keys | length) == 0,
			(.generate.data.spec.policyTypes | [(length == 2), contains(["Ingress"]), contains(["Egress"])] | all),
			(.generate.data.spec | has("ingress") | not),
			(.generate.data.spec | has("egress") | not)
		] | all
	' "$platform_policy" >/dev/null ||
		fail "Platform generated network floor no longer has the compatible default-deny, DNS, and standard-policy shape"

	# Bind the Gateway allowance to the rendered route, Service, and Deployment
	# rather than a duplicated literal port. A valid Kustomize patch must not be
	# able to move the workload while leaving this contract green.
	# shellcheck disable=SC2016
	yq eval -e '
		[
			.kind == "Service",
			.metadata.name == "app",
			(.metadata | has("namespace") | not),
			(.spec.selector | keys | length) == 1,
			.spec.selector."app.kubernetes.io/name" == "app",
			([.spec.ports[] | select([
				.name == "http",
				((.protocol // "TCP") == "TCP")
			] | all)] | length) == 1
		] | all
	' "$service" >/dev/null || fail "rendered tenant Service lacks one named HTTP port"
	# shellcheck disable=SC2016
	yq eval -e '
		[
			.kind == "Deployment",
			.metadata.name == "app",
			(.metadata | has("namespace") | not),
			(.spec.selector | keys | length) == 1,
			(.spec.selector.matchLabels | keys | length) == 1,
			.spec.selector.matchLabels."app.kubernetes.io/name" == "app",
			.spec.template.metadata.labels."app.kubernetes.io/name" == "app",
			([.spec.template.spec.containers[] | select(.name == "app")] | length) == 1
		] | all
	' "$deployment" >/dev/null || fail "rendered tenant Deployment lacks the app container"
	# shellcheck disable=SC2016
	yq eval -e '
		[
			.kind == "HTTPRoute",
			.metadata.name == "app",
			(.metadata | has("namespace") | not),
			(.spec.parentRefs | length) == 1,
			(.spec.parentRefs[0].group // "gateway.networking.k8s.io") == "gateway.networking.k8s.io",
			(.spec.parentRefs[0].kind // "Gateway") == "Gateway",
			.spec.parentRefs[0].name == "platform",
			.spec.parentRefs[0].namespace == "kube-system",
			.spec.parentRefs[0].sectionName == "https",
			(.spec.rules | length) == 1,
			(.spec.rules[0] | keys | length) == 1,
			(.spec.rules[0].backendRefs | length) == 1,
			([.spec.rules[].backendRefs[] | select([
				.name == "app",
				((.group // "") == ""),
				((.kind // "Service") == "Service"),
				(has("namespace") | not),
				((.weight // 1) > 0)
			] | all)] | length) == 1
		] | all
	' "$http_route" >/dev/null ||
		fail "rendered tenant HTTPRoute lacks one local core Service app backend"

	app_service_port=$(yq eval -r '.spec.ports[] | select(.name == "http") | .port | tostring' "$service")
	app_target_port=$(yq eval -r '.spec.ports[] | select(.name == "http") | .targetPort | tostring' "$service")
	case $app_service_port:$app_target_port in
		*null* | :* | *:) fail "rendered tenant Service has an incomplete HTTP port mapping" ;;
	esac
	export app_service_port app_target_port
	# shellcheck disable=SC2016
	yq eval -e '
		[.spec.template.spec.containers[]
			| select(.name == "app")
			| .ports[]
			| select((.containerPort | tostring) == strenv(app_target_port))
		] | length == 1
	' "$deployment" >/dev/null ||
		fail "rendered Service targetPort no longer matches the app container port"
	# shellcheck disable=SC2016
	yq eval -e '
		[.spec.rules[].backendRefs[]
			| select([
				.name == "app",
				((.group // "") == ""),
				((.kind // "Service") == "Service"),
				(has("namespace") | not),
				((.weight // 1) > 0),
				((.port | tostring) == strenv(app_service_port))
			] | all)
		] | length == 1
	' "$http_route" >/dev/null ||
		fail "rendered HTTPRoute backend port no longer matches the app Service port"

	# shellcheck disable=SC2016
	yq eval -e '
		[
			.kind == "CiliumNetworkPolicy",
			.metadata.name == "app",
			(.metadata | has("namespace") | not),
			(.spec.endpointSelector | keys | length) == 0,
			(.spec | has("ingressDeny") | not),
			(.spec | has("egressDeny") | not),
			(.spec.ingress | length) == 3,
			(.spec.egress | length) == 3,
			([.spec.ingress[] | select(.fromEntities | contains(["ingress"]))] | length) == 1,
			(.spec.ingress[] | select(.fromEntities | contains(["ingress"])) | keys | length) == 2,
			(.spec.ingress[] | select(.fromEntities | contains(["ingress"])) | .fromEntities | [(length == 1), contains(["ingress"])] | all),
			(.spec.ingress[] | select(.fromEntities | contains(["ingress"])) | .toPorts | length) == 1,
			(.spec.ingress[] | select(.fromEntities | contains(["ingress"])) | .toPorts[0] | keys | length) == 1,
			(.spec.ingress[] | select(.fromEntities | contains(["ingress"])) | .toPorts[0].ports | [(length == 1), contains([{"port": strenv(app_target_port), "protocol": "TCP"}])] | all),
			([.spec.ingress[] | select(has("fromEndpoints") and (.fromEndpoints[0] | keys | length == 0))] | length) == 1,
			(.spec.ingress[] | select(has("fromEndpoints") and (.fromEndpoints[0] | keys | length == 0)) | .fromEndpoints | length) == 1,
			(.spec.ingress[] | select(has("fromEndpoints") and (.fromEndpoints[0] | keys | length == 0)) | keys | length) == 1,
			([.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "cnpg-system")] | length) == 1,
			(.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "cnpg-system") | keys | length) == 2,
			(.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "cnpg-system") | .fromEndpoints | length) == 1,
			(.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "cnpg-system") | .fromEndpoints[0] | keys | length) == 1,
			(.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "cnpg-system") | .fromEndpoints[0].matchLabels | keys | length) == 1,
			(.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "cnpg-system") | .toPorts | length) == 1,
			(.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "cnpg-system") | .toPorts[0] | keys | length) == 1,
			(.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "cnpg-system") | .toPorts[0].ports | [(length == 2), contains([{"port": "5432", "protocol": "TCP"}]), contains([{"port": "8000", "protocol": "TCP"}])] | all),
			([.spec.egress[] | select(has("toEndpoints") and (.toEndpoints[0] | keys | length == 0))] | length) == 1,
			(.spec.egress[] | select(has("toEndpoints") and (.toEndpoints[0] | keys | length == 0)) | .toEndpoints | length) == 1,
			(.spec.egress[] | select(has("toEndpoints") and (.toEndpoints[0] | keys | length == 0)) | keys | length) == 1,
			([.spec.egress[] | select(.toEntities | contains(["kube-apiserver"]))] | length) == 1,
			(.spec.egress[] | select(.toEntities | contains(["kube-apiserver"])) | keys | length) == 1,
			(.spec.egress[] | select(.toEntities | contains(["kube-apiserver"])) | .toEntities | [(length == 1), contains(["kube-apiserver"])] | all),
			([.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns")] | length) == 1,
			(.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns") | keys | length) == 2,
			(.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns") | .toEndpoints | length) == 1,
			(.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns") | .toEndpoints[0] | keys | length) == 1,
			(.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns") | .toEndpoints[0].matchLabels | keys | length) == 2,
			(.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns") | .toEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "kube-system"),
			(.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns") | .toPorts | length) == 1,
			(.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns") | .toPorts[0] | keys | length) == 1,
			(.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns") | .toPorts[0].ports | [(length == 2), contains([{"port": "53", "protocol": "TCP"}]), contains([{"port": "53", "protocol": "UDP"}])] | all)
		] | all
	' "$scaffold_policy" >/dev/null ||
		fail "rendered tenant scaffold no longer re-opens Gateway, namespace, CNPG, Kubernetes API, and DNS traffic"
}

extract_rendered_resource() {
	rendered_bundle=$1
	resource_kind=$2
	resource_name=$3
	output_file=$4
	export resource_kind resource_name
	resource_count=$(yq eval-all '
		select([.kind == strenv(resource_kind), .metadata.name == strenv(resource_name)] | all)
		| .kind
	' "$rendered_bundle" | wc -l | tr -d ' ')
	[ "$resource_count" -eq 1 ] ||
		fail "rendered inventory has $resource_count $resource_kind/$resource_name resources; expected 1"
	yq eval-all '
		select([.kind == strenv(resource_kind), .metadata.name == strenv(resource_name)] | all)
	' "$rendered_bundle" > "$output_file"
}

validate_platform_network_inventory() {
	rendered_bundle=$1
	yq eval -o=json "$rendered_bundle" | jq -se '
		[.[]
			| select(.kind == "ClusterPolicy")
			| .metadata.name as $policy
			| .spec.rules[]?
			| select([
				.generate.kind == "CiliumNetworkPolicy",
				.generate.kind == "NetworkPolicy"
			] | any)
			| {
				policy: $policy,
				rule: .name,
				apiVersion: .generate.apiVersion,
				kind: .generate.kind,
				name: .generate.name,
				namespace: .generate.namespace
			}
		] | sort_by(.kind, .rule) == ([
			{
				policy: "add-default-deny",
				rule: "generate-default-deny",
				apiVersion: "cilium.io/v2",
				kind: "CiliumNetworkPolicy",
				name: "default-deny",
				namespace: "{{request.object.metadata.name}}"
			},
			{
				policy: "add-default-deny",
				rule: "generate-allow-dns",
				apiVersion: "cilium.io/v2",
				kind: "CiliumNetworkPolicy",
				name: "allow-dns",
				namespace: "{{request.object.metadata.name}}"
			},
			{
				policy: "add-default-deny",
				rule: "generate-default-deny-networkpolicy",
				apiVersion: "networking.k8s.io/v1",
				kind: "NetworkPolicy",
				name: "default-deny",
				namespace: "{{request.object.metadata.name}}"
			}
		] | sort_by(.kind, .rule))
	' >/dev/null ||
		fail "rendered Platform inventory has an unvalidated tenant network-policy generator"
}

render_platform_policy() {
	platform_checkout=$1
	output_dir=$2
	mkdir -p "$output_dir"
	rendered_bundle=$output_dir/all.yaml
	kubectl kustomize \
		"$platform_checkout/k8s/bases/infrastructure/cluster-policies" > "$rendered_bundle"
	validate_platform_network_inventory "$rendered_bundle"
	extract_rendered_resource \
		"$rendered_bundle" ClusterPolicy add-default-deny "$output_dir/add-default-deny.yaml"
}

render_scaffold() {
	deploy_root=$1
	output_dir=$2
	mkdir -p "$output_dir"
	rendered_bundle=$output_dir/all.yaml
	kubectl kustomize "$deploy_root" > "$rendered_bundle"
	extract_rendered_resource "$rendered_bundle" CiliumNetworkPolicy app "$output_dir/network-policy.yaml"
	extract_rendered_resource "$rendered_bundle" Service app "$output_dir/service.yaml"
	extract_rendered_resource "$rendered_bundle" Deployment app "$output_dir/deployment.yaml"
	extract_rendered_resource "$rendered_bundle" HTTPRoute app "$output_dir/http-route.yaml"
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 6 ] ||
		fail "usage: $0 --validate <platform-root> <network-policy> <service> <deployment> <http-route>"
	validation_dir=$(mktemp -d)
	trap 'rm -rf "$validation_dir"' EXIT
	render_platform_policy "$2" "$validation_dir"
	validate_network_floor \
		"$validation_dir/add-default-deny.yaml" \
		"$3" "$4" "$5" "$6"
	exit 0
fi

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT
rendered_root=$mutation_dir/rendered
render_scaffold "$repo_root/deploy" "$rendered_root"

platform_root=${PLATFORM_ROOT:-$repo_root/.platform}
rendered_platform_root=$mutation_dir/rendered-platform
render_platform_policy "$platform_root" "$rendered_platform_root"
platform_policy=$rendered_platform_root/add-default-deny.yaml
scaffold_policy=$rendered_root/network-policy.yaml
service=$rendered_root/service.yaml
deployment=$rendered_root/deployment.yaml
http_route=$rendered_root/http-route.yaml
validate_network_floor "$platform_policy" "$scaffold_policy" "$service" "$deployment" "$http_route"
validate_platform_route_hostnames "$platform_root" "$http_route"

platform_baseline=$mutation_dir/platform.yaml
scaffold_baseline=$mutation_dir/scaffold.yaml
service_baseline=$mutation_dir/service.yaml
deployment_baseline=$mutation_dir/deployment.yaml
http_route_baseline=$mutation_dir/http-route.yaml
cp "$platform_policy" "$platform_baseline"
cp "$scaffold_policy" "$scaffold_baseline"
cp "$service" "$service_baseline"
cp "$deployment" "$deployment_baseline"
cp "$http_route" "$http_route_baseline"

run_platform_mutation() {
	description=$1
	mutation=$2
	yq eval "$mutation" "$platform_baseline" > "$mutation_dir/platform-mutant.yaml"
	if (validate_network_floor \
		"$mutation_dir/platform-mutant.yaml" \
		"$scaffold_baseline" \
		"$service_baseline" \
		"$deployment_baseline" \
		"$http_route_baseline") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_scaffold_mutation() {
	description=$1
	mutation=$2
	yq eval "$mutation" "$scaffold_baseline" > "$mutation_dir/scaffold-mutant.yaml"
	if (validate_network_floor \
		"$platform_baseline" \
		"$mutation_dir/scaffold-mutant.yaml" \
		"$service_baseline" \
		"$deployment_baseline" \
		"$http_route_baseline") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_service_mutation() {
	description=$1
	mutation=$2
	yq eval "$mutation" "$service_baseline" > "$mutation_dir/service-mutant.yaml"
	if (validate_network_floor \
		"$platform_baseline" \
		"$scaffold_baseline" \
		"$mutation_dir/service-mutant.yaml" \
		"$deployment_baseline" \
		"$http_route_baseline") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_deployment_mutation() {
	description=$1
	mutation=$2
	yq eval "$mutation" "$deployment_baseline" > "$mutation_dir/deployment-mutant.yaml"
	if (validate_network_floor \
		"$platform_baseline" \
		"$scaffold_baseline" \
		"$service_baseline" \
		"$mutation_dir/deployment-mutant.yaml" \
		"$http_route_baseline") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_http_route_mutation() {
	description=$1
	mutation=$2
	yq eval "$mutation" "$http_route_baseline" > "$mutation_dir/http-route-mutant.yaml"
	if (validate_network_floor \
		"$platform_baseline" \
		"$scaffold_baseline" \
		"$service_baseline" \
		"$deployment_baseline" \
		"$mutation_dir/http-route-mutant.yaml" &&
		validate_platform_route_hostnames \
			"$platform_root" \
			"$mutation_dir/http-route-mutant.yaml") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_hostname_mutation() {
	description=$1
	local_mutation=$2
	prod_mutation=$3
	route_mutation=$4
	missing_source=${5:-}
	mutant_platform_root=$mutation_dir/hostname-platform-mutant
	mutant_local=$mutant_platform_root/k8s/clusters/local/bootstrap/config-map.yaml
	mutant_prod=$mutant_platform_root/k8s/clusters/prod/bootstrap/config-map.yaml
	mutant_route=$mutation_dir/hostname-route-mutant.yaml

	mkdir -p "$(dirname "$mutant_local")" "$(dirname "$mutant_prod")"
	cp "$platform_root/k8s/clusters/local/bootstrap/config-map.yaml" "$mutant_local"
	cp "$platform_root/k8s/clusters/prod/bootstrap/config-map.yaml" "$mutant_prod"
	cp "$http_route_baseline" "$mutant_route"
	if [ -n "$local_mutation" ]; then
		yq eval "$local_mutation" "$mutant_local" > "$mutation_dir/local-domain-mutant.yaml"
		mv "$mutation_dir/local-domain-mutant.yaml" "$mutant_local"
	fi
	if [ -n "$prod_mutation" ]; then
		yq eval "$prod_mutation" "$mutant_prod" > "$mutation_dir/prod-domain-mutant.yaml"
		mv "$mutation_dir/prod-domain-mutant.yaml" "$mutant_prod"
	fi
	if [ -n "$route_mutation" ]; then
		yq eval "$route_mutation" "$mutant_route" > "$mutation_dir/hostname-route-mutant-next.yaml"
		mv "$mutation_dir/hostname-route-mutant-next.yaml" "$mutant_route"
	fi
	if [ -n "$missing_source" ]; then
		rm -f "$mutant_platform_root/$missing_source"
	fi

	if (validate_platform_route_hostnames "$mutant_platform_root" "$mutant_route") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_rendered_scaffold_mutation() {
	description=$1
	mutation=$2
	mutant_deploy=$mutation_dir/deploy-mutant
	mutant_rendered=$mutation_dir/rendered-mutant
	cp -R "$repo_root/deploy" "$mutant_deploy"
	yq eval "$mutation" "$mutant_deploy/kustomization.yaml" > "$mutation_dir/kustomization-mutant.yaml"
	mv "$mutation_dir/kustomization-mutant.yaml" "$mutant_deploy/kustomization.yaml"
	render_scaffold "$mutant_deploy" "$mutant_rendered"
	if (validate_network_floor \
		"$platform_baseline" \
		"$mutant_rendered/network-policy.yaml" \
		"$mutant_rendered/service.yaml" \
		"$mutant_rendered/deployment.yaml" \
		"$mutant_rendered/http-route.yaml") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_platform_inventory_mutation() {
	description=$1
	mutation=$2
	mutant_platform_root=$mutation_dir/platform-inventory-mutant
	mutant_inventory=$mutant_platform_root/k8s/bases/infrastructure/cluster-policies
	mkdir -p "$mutant_platform_root/k8s/bases/infrastructure"
	cp -R "$platform_root/k8s/bases/infrastructure/cluster-policies" "$mutant_inventory"
	yq eval "$mutation" "$mutant_inventory/kustomization.yaml" > "$mutation_dir/platform-kustomization-mutant.yaml"
	mv "$mutation_dir/platform-kustomization-mutant.yaml" "$mutant_inventory/kustomization.yaml"
	if sh "$script_dir/platform-network-floor.test.sh" --validate \
		"$mutant_platform_root" \
		"$scaffold_baseline" \
		"$service_baseline" \
		"$deployment_baseline" \
		"$http_route_baseline" >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_additional_platform_policy_mutation() {
	description=$1
	mutation=$2
	mutant_platform_root=$mutation_dir/additional-policy-mutant
	mutant_inventory=$mutant_platform_root/k8s/bases/infrastructure/cluster-policies
	mutant_policy=$mutant_inventory/best-practices/add-default-limitrange.yaml
	mkdir -p "$mutant_platform_root/k8s/bases/infrastructure"
	cp -R "$platform_root/k8s/bases/infrastructure/cluster-policies" "$mutant_inventory"
	yq eval "$mutation" "$mutant_policy" > "$mutation_dir/additional-policy-mutant.yaml"
	mv "$mutation_dir/additional-policy-mutant.yaml" "$mutant_policy"
	if sh "$script_dir/platform-network-floor.test.sh" --validate \
		"$mutant_platform_root" \
		"$scaffold_baseline" \
		"$service_baseline" \
		"$deployment_baseline" \
		"$http_route_baseline" >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_platform_mutation "matched ingress deny introduced" \
	'(.spec.rules[] | select(.name == "generate-default-deny").generate.data.spec.ingressDeny[0].fromEntities) = ["all"]'
run_platform_mutation "default-deny ingress allowance broadened" \
	'(.spec.rules[] | select(.name == "generate-default-deny").generate.data.spec.ingress) = [{"fromEntities": ["all"]}]'
run_platform_mutation "default-deny egress allowance broadened" \
	'(.spec.rules[] | select(.name == "generate-default-deny").generate.data.spec.egress) = [{"toEntities": ["all"]}]'
run_platform_mutation "default-deny ingress isolation disabled" \
	'(.spec.rules[] | select(.name == "generate-default-deny").generate.data.spec.enableDefaultDeny.ingress) = false'
run_platform_mutation "default-deny egress isolation disabled" \
	'(.spec.rules[] | select(.name == "generate-default-deny").generate.data.spec.enableDefaultDeny.egress) = false'
# An empty scalar is not an empty allow list: yq reports length 0 for null and
# for "", so only the sequence-tag assertion rejects a direction that stopped
# being a list. Cilium requires the direction to be present AND a list.
run_platform_mutation "default-deny ingress replaced by a null scalar" \
	'(.spec.rules[] | select(.name == "generate-default-deny").generate.data.spec.ingress) = null'
run_platform_mutation "default-deny egress replaced by an empty string" \
	'(.spec.rules[] | select(.name == "generate-default-deny").generate.data.spec.egress) = ""'
run_platform_inventory_mutation "generated floor removed from rendered Platform inventory" \
	'del(.resources[] | select(. == "best-practices/add-default-deny.yaml"))'
run_additional_platform_policy_mutation "network policy generated outside add-default-deny" \
	'.spec.rules += [{"name": "generate-world-egress", "match": {"any": [{"resources": {"kinds": ["Namespace"]}}]}, "generate": {"apiVersion": "cilium.io/v2", "kind": "CiliumNetworkPolicy", "name": "world-egress", "namespace": "{{request.object.metadata.name}}", "data": {"spec": {"endpointSelector": {}, "egress": [{"toEntities": ["world"]}]}}}}]'
run_platform_mutation "default-deny generation removed" \
	'del(.spec.rules[] | select(.name == "generate-default-deny"))'
run_platform_mutation "additional generated network-policy rule introduced" \
	'.spec.rules += [{"name": "generate-world-egress", "match": {"any": [{"resources": {"kinds": ["Namespace"]}}]}, "generate": {"apiVersion": "cilium.io/v2", "kind": "CiliumNetworkPolicy", "name": "world-egress", "namespace": "{{request.object.metadata.name}}", "data": {"spec": {"endpointSelector": {}, "egress": [{"toEntities": ["world"]}]}}}}]'
run_platform_mutation "only the first matching generation rule executes" \
	'.spec.applyRules = "One"'
run_platform_mutation "tenant namespace target removed" \
	'del(.spec.rules[] | select(.name == "generate-default-deny").generate.namespace)'
run_platform_mutation "additional namespace exclusion introduced" \
	'.spec.rules[] |= select(.name == "generate-default-deny") * {"exclude": {"any": (.exclude.any + [{"resources": {"selector": {"matchLabels": {"platform.devantler.tech/tenant": "true"}}}}])}}'
run_platform_mutation "additional match-all condition suppresses generation" \
	'(.spec.rules[] | select(.name == "generate-default-deny").match.all) = [{"resources": {"names": ["never-match"]}}]'
run_platform_mutation "additional exclude-all condition suppresses generation" \
	'(.spec.rules[] | select(.name == "generate-default-deny").exclude.all) = [{"resources": {"selector": {"matchLabels": {"platform.devantler.tech/tenant": "true"}}}}]'
run_platform_mutation "generation-suppressing precondition introduced" \
	'(.spec.rules[] | select(.name == "generate-default-deny").preconditions) = {"all": [{"key": "{{request.object.metadata.name}}", "operator": "Equals", "value": "never-match"}]}'
run_platform_mutation "generated DNS TCP allowance removed" \
	'del(.spec.rules[] | select(.name == "generate-allow-dns").generate.data.spec.egress[0].toPorts[0].ports[] | select(.protocol == "TCP"))'
run_platform_mutation "generated DNS deny override introduced" \
	'(.spec.rules[] | select(.name == "generate-allow-dns").generate.data.spec.egressDeny) = [{"toEntities": ["all"]}]'
run_platform_mutation "generated DNS allowance broadened to world egress" \
	'(.spec.rules[] | select(.name == "generate-allow-dns").generate.data.spec.egress) += [{"toEntities": ["world"]}]'
run_platform_mutation "standard default-deny kind changed" \
	'(.spec.rules[] | select(.name == "generate-default-deny-networkpolicy").generate.kind) = "CiliumNetworkPolicy"'
run_scaffold_mutation "Gateway ingress allowance removed" \
	'(.spec.ingress[] | select(.fromEntities | contains(["ingress"])).fromEntities) = ["cluster"]'
run_scaffold_mutation "Gateway ingress gains an additional port block" \
	'(.spec.ingress[] | select(.fromEntities | contains(["ingress"])).toPorts) += [{"ports": [{"port": "8080", "protocol": "TCP"}]}]'
run_scaffold_mutation "unexpected world ingress allowance added" \
	'.spec.ingress += [{"fromEntities": ["world"]}]'
run_scaffold_mutation "same-namespace ingress allowance removed" \
	'del(.spec.ingress[] | select(.fromEndpoints[0] | keys | length == 0))'
run_scaffold_mutation "same-namespace ingress adds another selector" \
	'(.spec.ingress[] | select(.fromEndpoints[0] | keys | length == 0).fromEndpoints) += [{"matchLabels": {"k8s:io.kubernetes.pod.namespace": "other"}}]'
run_scaffold_mutation "same-namespace ingress restricted to one port" \
	'(.spec.ingress[] | select(.fromEndpoints[0] | keys | length == 0).toPorts) = [{"ports": [{"port": "3000", "protocol": "TCP"}]}]'
run_scaffold_mutation "Kubernetes API egress allowance removed" \
	'(.spec.egress[] | select(.toEntities | contains(["kube-apiserver"])).toEntities) = ["host"]'
run_scaffold_mutation "Kubernetes API egress allowance broadened to world" \
	'(.spec.egress[] | select(.toEntities | contains(["kube-apiserver"])).toEntities) += ["world"]'
run_scaffold_mutation "unexpected world egress allowance added" \
	'.spec.egress += [{"toEntities": ["world"]}]'
run_scaffold_mutation "same-namespace egress adds another selector" \
	'(.spec.egress[] | select(.toEndpoints[0] | keys | length == 0).toEndpoints) += [{"matchLabels": {"k8s:io.kubernetes.pod.namespace": "other"}}]'
run_scaffold_mutation "tenant DNS UDP allowance removed" \
	'del(.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns").toPorts[0].ports[] | select(.protocol == "UDP"))'
run_scaffold_mutation "tenant Gateway deny override introduced" \
	'.spec.ingressDeny = [{"fromEntities": ["ingress"]}]'
run_scaffold_mutation "network policy moved outside the workload namespace" \
	'.metadata.namespace = "other-namespace"'
run_scaffold_mutation "CNPG selector restricted away from operator pods" \
	'(.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "cnpg-system").fromEndpoints[0].matchLabels."app.kubernetes.io/name") = "nonexistent"'
run_scaffold_mutation "CNPG ingress gains an additional port block" \
	'(.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "cnpg-system").toPorts) += [{"ports": [{"port": "8080", "protocol": "TCP"}]}]'
run_service_mutation "Service target port diverged from workload and network policy" \
	'(.spec.ports[] | select(.name == "http").targetPort) = 3001'
run_service_mutation "Service selector diverged from workload labels" \
	'.spec.selector."app.kubernetes.io/name" = "other-app"'
run_service_mutation "Service HTTP protocol changed to UDP" \
	'(.spec.ports[] | select(.name == "http").protocol) = "UDP"'
run_deployment_mutation "Deployment selector diverged from pod labels" \
	'.spec.selector.matchLabels."app.kubernetes.io/name" = "other-app"'
run_http_route_mutation "HTTPRoute detached from the Platform Gateway" \
	'.spec.parentRefs[0].name = "other-gateway"'
run_http_route_mutation "HTTPRoute hostname broadened to wildcard" \
	'.spec.hostnames = ["*.platform.lan"]'
run_hostname_mutation "local Platform hostname removed" '' '' \
	'del(.spec.hostnames[] | select(. == "app.platform.lan"))'
run_hostname_mutation "production Platform hostname removed" '' '' \
	'del(.spec.hostnames[] | select(. == "app.platform.devantler.tech"))'
run_hostname_mutation "production Platform hostname uses the wrong suffix" '' '' \
	'(.spec.hostnames[] | select(. == "app.platform.devantler.tech")) = "app.platform.example.com"'
run_hostname_mutation "local Platform domain source removed" '' '' '' \
	'k8s/clusters/local/bootstrap/config-map.yaml'
run_hostname_mutation "production Platform domain source removed" '' '' '' \
	'k8s/clusters/prod/bootstrap/config-map.yaml'
run_http_route_mutation "HTTPRoute parent changed from a Gateway" \
	'.spec.parentRefs[0] *= {"group": "apps", "kind": "Deployment"}'
run_http_route_mutation "HTTPRoute backend moved to another namespace" \
	'.spec.rules[0].backendRefs[0].namespace = "other-namespace"'
run_http_route_mutation "HTTPRoute backend disabled with zero weight" \
	'.spec.rules[0].backendRefs[0].weight = 0'
run_http_route_mutation "HTTPRoute backend rule replaced by a redirect filter" \
	'.spec.rules[0].filters = [{"type": "RequestRedirect", "requestRedirect": {"scheme": "https"}}]'
run_http_route_mutation "HTTPRoute backend changed from a core Service" \
	'.spec.rules[0].backendRefs[0] *= {"group": "apps", "kind": "Deployment"}'
run_http_route_mutation "HTTPRoute backend identity and port split across different refs" \
	'.spec.rules[0].backendRefs = [{"name": "app", "port": 81}, {"name": "app", "namespace": "other-namespace", "port": 80}]'
run_rendered_scaffold_mutation "Kustomize patch removed rendered Gateway allowance" \
	'.patches = [{"target": {"kind": "CiliumNetworkPolicy", "name": "app"}, "patch": "- op: remove\n  path: /spec/ingress/0"}]'

echo "PASS: Platform network floor (generated policies + tenant allows + live route domains + 54 safety mutations)"
