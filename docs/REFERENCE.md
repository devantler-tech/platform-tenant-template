# Template reference

The detail behind the [README](../README.md): what the placeholder rename changes, which files the
template keeps in sync and which are yours, how publishing works, and how to validate the template
locally.

## What the rename changes

`scripts/rename-placeholders.sh` rewrites the `app`, `REPLACE_ME`, and `replace-me`
placeholders in `deploy/` consistently, including the container name, Vault role,
and ServiceAccount. Those values **must** equal the repository name (see the
convention under [How publishing works](#how-publishing-works)). The helper
preserves the `app.kubernetes.io/name` label *keys*, CloudNativePG's literal `-app`
secret suffix, and the `openbao` SecretStore name. Doing this by hand is easy to get
half-wrong. It's a one-shot helper, so delete it once adopted.

The example route is renamed for both environments: `<tenant>.platform.lan`
locally and `<tenant>.platform.devantler.tech` in production, both in
`deploy/httproute.yaml`. Add any custom domains beside them; a tenant that moves
to its own canonical domain may drop the `platform.devantler.tech` hostname. Each
Platform Gateway attaches only the hostnames its listener serves.

The route also publishes a tile to the Platform Homepage. The helper updates
its name, production URL, and pod selector; tailor the tile's description,
group, and icon annotations after the rename to describe your app. If you drop
the `platform.devantler.tech` hostname, point the tile's `gethomepage.dev/href`
annotation at your canonical domain too, or the tile links to an address the
route no longer serves.

## What the template owns vs. what you own

template-sync overwrites the files the template **owns** and never touches the
files **you own**. Declare the files you own in **`.templatesyncignore`** (same
syntax as `.gitignore`). template-sync only ever brings over files that exist in
this template, so you only need to ignore the scaffolding files below — not your
app code.

Your `.templatesyncignore` is never overwritten. The current scaffold's
[sync caller](../.github/workflows/template-sync.yaml) enables
`merge-template-ignore-entries`, so it adds entries from the template's list
that yours lacks and keeps your own entries. Older consumer callers may not
enable that option. Before their sync runs, add and commit any missing ownership
entry yourself. If a sync PR has already proposed replacing an owned guide,
restore the tailored guide and commit the ignore entry before merging it;
changing the ignore file does not undo an existing proposal. To receive a file
the template excludes, add the line `!<entry>` to your list.

**Owned by the template (kept in sync — do not edit in your tenant):**

| File | Purpose |
|---|---|
| `.github/workflows/cd.yaml` | On a `v*` tag, calls `publish-app.yaml` to build, digest-pin, push, and **cosign-sign** the image + manifests OCI artifact |
| `.github/workflows/release.yaml` | semantic-release on `main` (cuts the `v*` tags that drive `cd.yaml`) |
| `.github/workflows/template-sync.yaml` | Opens the weekly template-sync PR |
| `CLAUDE.md` | `@AGENTS.md` shim |
| `docs/REFERENCE.md` | This reference |
| `scripts/workflow-caller-pin-contract.test.sh` | Runs in each tenant's required CI and rejects malformed, divergent, or rolled-back reusable-workflow pins, and a version comment that does not name the tag of the pinned commit |
| `scripts/publish-pin-approved.sh`, `scripts/publish-pin-approved.test.sh` | The check a tenant's required CI runs to refuse a changed publisher identity until Platform approves it for that tenant. Legacy revisions use the existing approved set; maintained publishers require an exact canonical approval. The default `ci.yaml` runs the `publish-pin-approved` job and includes it in `ci-required-checks`; this unregistered template runs its tests only. Older tenants that own `ci.yaml` add the job themselves |
| `zizmor.yml` | GitHub Actions pinning policy enforced by the security scan |

**Scaffold-time only (arrives when the repo is created — never re-synced, so a
tenant still carrying these from an older sync can delete them for good):**

| File | Purpose |
|---|---|
| `.github/workflows/validate-scaffold.yaml` | Renders `deploy/`, schema-validates every resource, applies the live Platform/shared Kyverno policies, and exercises a pinned Kubernetes API. The live checks prove the template publishes through the pinned signing workflow; Platform still wires the private GHCR pull credential to the tenant identity and cosign-verifying OCI source; and Flux consumes that source while impersonating and targeting the managed `restricted` namespace for both KRO and manual registrations. They then prove the Deployment passes Pod Security `restricted`, the tenant identity can reconcile every rendered kind, and cluster-scoped or interactive privileges remain denied. It gates template PRs, re-validates `main` after every merge, and rechecks upstream drift every day at 06:17 UTC (or on manual dispatch), keeping one tracking issue open while that scheduled check fails on `main`; structural mutation tests keep every layer fail-closed. The workflow no-ops in tenants and is scaffold-time only |
| `scripts/rename-placeholders.sh` (+ its test) | One-shot rename of the placeholder app to your tenant name |
| `scripts/agent-instructions.test.sh` | Fails closed if the one-time agent scaffold loses its ownership, dependency-bot, external-code, exact-head review, pinned-merge, or user-path evaluation boundaries, or regains a retired rule |
| `scripts/workflow-caller-contract.test.sh` | Keeps the portable caller-pin contract wired into tenant CI while validating template-only publisher, release, ownership, and scaffold invariants |
| `scripts/tenant-ci-contract.test.sh` | Keeps default tenant PR CI least-privilege and fail-closed over both the image build and rendered manifests |
| `scripts/pod-security-admission*.test.sh` | Proves the rendered Deployment is accepted at Pod Security `restricted` while unsafe mutations are denied, and pins that live gate against structural bypasses |
| `scripts/tenant-rbac*.test.sh` | Proves the Platform tenant reconciliation identity can manage every rendered scaffold resource while cluster-scoped and interactive privileges stay denied |
| `scripts/platform-tenant-envelope*.test.sh` | Binds the template's signed publisher and those workload-level models to Platform's live KRO and manual tenant registrations: private GHCR pull identity, cosign-verifying OCI source, managed Pod Security namespace, `tenant-edit` ServiceAccount binding, Flux source/impersonation/target namespace, and the exact OpenBao policy and Kubernetes-auth role that let the renamed tenant read and seed only its own app secrets |
| `scripts/platform-network-floor*.test.sh` | Binds Platform's generated default-deny, DNS, and standard NetworkPolicy floor to the scaffold's required Gateway, namespace, CNPG, Kubernetes API, and DNS paths, reporting a check that cannot read its input separately from a policy verdict |
| `scripts/platform-vpa-floor*.test.sh` | Uses Kyverno to evaluate Platform's Deployment GeneratingPolicy and keeps the scaffold's initial CPU request at or above the generated VPA floor, with mutation coverage |

**Yours (list these in `.templatesyncignore`):**

```gitignore
# Files this tenant owns — template-sync must never overwrite them.
AGENTS.md
.claude/skills/maintain/SKILL.md
.github/CODEOWNERS
.github/workflows/ci.yaml
.github/dependabot.yml
.releaserc
.gitignore
Dockerfile
README.md
CONTRIBUTING.md
LICENSE
deploy/
.templatesyncignore

# Template scaffolding — dead code in a live tenant; keep ignored so a
# template-sync never re-introduces it after you delete it.
scripts/rename-placeholders.sh
scripts/rename-placeholders.test.sh
scripts/agent-instructions.test.sh
scripts/workflow-caller-contract.test.sh
scripts/tenant-ci-contract.test.sh
scripts/pod-security-admission.test.sh
scripts/pod-security-admission-contract.test.sh
scripts/tenant-rbac.test.sh
scripts/tenant-rbac-contract.test.sh
scripts/platform-tenant-envelope.test.sh
scripts/platform-tenant-envelope-contract.test.sh
scripts/platform-network-floor.test.sh
scripts/platform-network-floor-contract.test.sh
scripts/platform-vpa-floor.test.sh
scripts/platform-vpa-floor-contract.test.sh
.github/workflows/validate-scaffold.yaml
```

`AGENTS.md` and the `maintain` skill ship as scaffolding (a starting point for new
tenants) but are **yours** — they carry your project-specific overview, so they are
ignored from sync. `.github/CODEOWNERS` is likewise yours: it names *your* tenant's
code owners, so template-sync never overwrites it.

## How publishing works

In generated tenant repositories with the required App setup, `release.yaml`
uses eligible Conventional-Commit merges to `main` to decide whether to create
`vX.Y.Z` tags. It deliberately no-ops in this upstream template. `.releaserc`
cuts a release for `feat`, `fix`, `perf`, breaking and `build(deps)` commits;
`build(deps)` is Dependabot's prefix for runtime packages and the Docker base
image, so their updates reach production on their own. GitHub Actions updates
use the `ci` prefix (set in `.github/dependabot.yml`) and release nothing.
Tenants own both files, so an existing tenant adds the `build(deps)` rule and
the `ci` prefix itself.
Each tag triggers `cd.yaml`, which calls the platform's
[`publish-app.yaml`](https://github.com/devantler-tech/.github/blob/main/.github/workflows/publish-app.yaml)
reusable workflow to build the image, **pin its digest into
`deploy/deployment.yaml`**, push the manifests as an OCI artifact, and
**cosign-sign** both. The platform's `OCIRepository` verifies that signature, so
only artifacts from this trusted workflow are eligible for reconciliation after
the platform has registered the tenant and its applicable publisher-approval
checks pass. Workflow configuration alone does not prove that publication or
reconciliation succeeded.

Before moving a publisher between repositories, merge and template-sync the
approval check first. CI executes the check from the base revision so the
repoint cannot authorize itself. The same commit identifier in another
repository is a changed identity, not an unchanged pin. Maintained publishing
requires the tenant's exact `publish-app` approval in Platform's canonical
record, with at most two distinct reviewed commits during a transition; legacy
approvals do not authorize it. Merge and verify the corresponding Platform
approval and image/manifest verification policy before changing a tenant caller.

The live envelope check accepts the manual tenant matcher's strict writer forms:
one to three distinct legacy commit IDs, optionally paired with one or two
distinct maintained commit IDs. Both locations must name the same app publisher,
all IDs must be full lowercase commit IDs, and the whole subject must be anchored.
Its controls exercise copies of the Platform envelope and reject mutable refs,
wildcards, wrong producers, duplicate IDs and excess approvals. This checks the
writer's narrow shape; Platform still owns which exact revisions are approved.
The generic KRO rule may retain the existing legacy full-commit pattern, alone
or paired with one or two literal maintained commits. Its rule must also match
the starter's actual pinned publisher identity; recognizing a valid rule shape
does not establish that the producer and consumer agree. Maintained wildcards,
mutable callers, multiple YAML documents and control characters are rejected.
The current conditional TenantSource form is recognized without executing CEL:
the default subject is decoded and checked against the actual caller, while the
explicit arm must retain its exact maintained-publisher path and full-revision
schema. Digest selection must retain the immutable digest schema, and optional
application reconciliation must default on and preserve its deletion guard.
Static OCI references remain supported; conditional application reconciliation
still requires the same source schema and safeguards with that reference form.
The starter uses the maintained publisher at its reviewed minimum version.
Its portable guard rejects a return to the retired catalogue, movable refs,
older versions and version comments that do not match the immutable commit.
The Platform approval and verification policy must be deployed before a live
tenant adopts that caller. This compatibility check does not activate publishing
or authorize a tenant's caller pin.

> **Convention:** the Deployment's container `name` MUST equal the repository
> name — `publish-app` pins the built image digest into the container with that
> name (`app-name: ${{ github.event.repository.name }}` in `cd.yaml`).

## Validate locally

Run these from the repository root. In every tenant, and in this template:

```sh
kubectl kustomize deploy/                              # manifests build
sh scripts/workflow-caller-pin-contract.test.sh       # portable tenant caller-pin contract (resolves the version-comment tag on github.com and compares it with the pinned commit)
sh scripts/publish-pin-approved.test.sh               # publish-app pin approval check (reads a local approved set, never the network)
actionlint .github/workflows/*                         # workflows parse
```

Additionally, in this template repository. A new tenant starts with these
scaffold-time scripts, but template sync never updates them, so a tenant that
keeps them runs them against stale copies; live tenants delete and ignore them:

```sh
sh scripts/rename-placeholders.test.sh                # onboarding contract
sh scripts/agent-instructions.test.sh                 # agent safety contract
sh scripts/workflow-caller-contract.test.sh           # template-only caller/scaffold contract
sh scripts/tenant-ci-contract.test.sh                 # tenant delivery-input CI contract
sh scripts/pod-security-admission-contract.test.sh    # Pod Security workflow contract
sh scripts/tenant-rbac-contract.test.sh               # Platform tenant RBAC workflow contract
sh scripts/platform-tenant-envelope-contract.test.sh  # live Platform tenant-envelope contract
sh scripts/platform-network-floor-contract.test.sh    # generated Platform network-floor contract
sh scripts/platform-vpa-floor-contract.test.sh        # generated Platform VPA-floor contract
```

The live VPA-floor check additionally needs Kyverno CLI 1.19.1 or later and a
read-only Platform checkout at `.platform` (or `PLATFORM_ROOT`). It evaluates the
Deployment policy locally against a copy of the scaffold in a test namespace;
it does not contact a cluster. Run `sh scripts/platform-vpa-floor.test.sh` with
`kyverno` on `PATH`, or set `KYVERNO_CLI` to the binary's path. The workflow
downloads and checksum-verifies its pinned CLI before this check.
