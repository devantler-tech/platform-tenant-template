# Template reference

The detail behind the [README](../README.md): what the scaffold and the placeholder rename change,
which files the template keeps in sync and which are yours, how publishing works, and how to validate
the template locally.

## What the scaffold changes

`scripts/scaffold.sh <go|dotnet|svelte|none> [--tenancy] [name]` runs once in a repository created from
this template. `name` defaults to the checkout's directory name and must be a DNS-1123 label equal
to the repository name.

- **Stack.** `go`, `dotnet` and `svelte` copy `stacks/<stack>/` over the template: the source and tests,
  lint and analyzer configuration, a Dockerfile, and the stack's CI job, which replaces the
  placeholder `stack` job in `.github/workflows/ci.yaml`. The stack's Dependabot ecosystem is
  appended to `.github/dependabot.yml` and its `## Stack` and `## Validation` text replaces the
  placeholders in `AGENTS.md`. The Go module becomes `github.com/devantler-tech/<name>`; the .NET
  solution, projects and namespace become the PascalCase form of `<name>`; the SvelteKit package
  becomes `<name>`. `none` keeps the placeholder job, and with `--tenancy` the placeholder
  Dockerfile, for a stack you bring yourself; without `--tenancy` you add your own build files.
  Every stack except Go keeps the `lint` job, which calls the shared MegaLinter workflow; a Go
  application drops it because the shared Go validator already runs MegaLinter.
- **Tenancy.** With `--tenancy` the application stays a platform tenant: `deploy/`, `cd.yaml`,
  the image's Dependabot entry, `renovate.json` and the CI jobs that guard the image and manifests
  stay, and
  `scripts/rename-placeholders.sh` renames `deploy/` (below). Without it, all of them are
  removed and the tenant-only template files are added to `.templatesyncignore`, so template-sync
  never brings them back.
- **Template machinery.** `stacks/`, the scaffold, the template's own validation workflows and its
  scaffold-time tests are removed; `.templatesyncignore` already lists each of them.

The edits follow `stack`, `lint`, `tenancy` and `template` markers in `ci.yaml`, `dependabot.yml`
and `AGENTS.md`, so none are left behind. The CI aggregate consumes `needs.*.result`, so dropping a job
and its `needs` entry leaves nothing else to edit. The scaffold refuses an unknown stack or option,
an invalid name, a second run and the upstream template checkout before it changes anything.

## What the rename changes

With `--tenancy`, `scripts/scaffold.sh` runs `scripts/rename-placeholders.sh`, which rewrites the `app`, `REPLACE_ME`, and `replace-me`
placeholders in `deploy/`, `base/`, `prod/` and `dev/` consistently, including the container name, Vault role,
and ServiceAccount. Those values **must** equal the repository name (see the
convention under [How publishing works](#how-publishing-works)). The helper
preserves the `app.kubernetes.io/name` label *keys*, CloudNativePG's literal `-app`
secret suffix, and the `openbao` SecretStore name. Doing this by hand is easy to get
half-wrong. It's a one-shot helper: the scaffold removes it once it has run.

The example route is renamed for both environments: `<tenant>.platform.lan`
locally and `<tenant>.platform.devantler.tech` in production, both in
`deploy/prod/httproute.yaml`. Add any custom domains beside them; a tenant that moves
to its own canonical domain may drop the `platform.devantler.tech` hostname. Each
Platform Gateway attaches only the hostnames its listener serves.

The route also publishes a tile to the Platform Homepage. The helper updates
its name, production URL, and pod selector; tailor the tile's description,
group, and icon annotations after the rename to describe your app. If you drop
the `platform.devantler.tech` hostname, point the tile's `gethomepage.dev/href`
annotation at your canonical domain too, or the tile links to an address the
route no longer serves.

## The deploy layout

Every custom-built app gets a production and a dev environment. Both reconcile
the same signed artifact, which holds the whole `deploy/` tree, so the tree is
split into Kustomize overlays that share one copy of each manifest:

```text
deploy/
├── kustomization.yaml   # production entry: includes only ./prod
├── base/                # what production and dev both run
├── prod/                # ../base + production-only objects
└── dev/                 # ../base + dev patches
```

- **`deploy/kustomization.yaml`** is what the platform reconciles for production,
  at `path: .`. Keep it to `resources: [prod]`.
- **`deploy/base/`** holds every manifest both environments run unchanged: the
  Deployment, whose app container receives the published image digest, the
  Service, the network policy and an optional CNPG database. In dev that
  database is a separate, empty instance in the dev namespace.
- **`deploy/prod/`** adds what only production runs: public routes and
  hostnames, certificates and DNS, PodDisruptionBudgets, backups, and anything
  that reads production data or holds a production credential or secret path,
  such as the OpenBao `SecretStore` and `ExternalSecret`.
- **`deploy/dev/`** changes base objects only with Kustomize `replicas` and
  `patches`, never a copied manifest. It runs one replica and adds no route,
  PDB, backup or production secret path: the platform reconciles it at
  `path: ./dev` into a `<tenant>-dev` namespace and owns its ingress behind
  sign-on ([platform#6126](https://github.com/devantler-tech/platform/issues/6126)).
  Turn on experimental features here only through runtime settings, such as an
  environment variable patched onto the Deployment.

Overlays reference only `../base` and their own files, so every directory builds
under Kustomize's default load restrictions. A secret the app needs in both
environments needs a dev source of its own in `deploy/dev`; reference a
production-only secret from a patch in `deploy/prod`.

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

**Owned by the template (kept in sync — do not edit in your application).** Rows marked
*tenant* exist only in platform tenants; an application scaffolded without `--tenancy` ignores them:

| File | Purpose |
|---|---|
| `.github/workflows/cd.yaml` (*tenant*) | On a `v*` tag, runs the pinned `actions/publish-app` action to build, digest-pin, push and sign the image and manifests as this repository’s own release workflow |
| `.github/workflows/release.yaml` | semantic-release on `main` (cuts the `v*` tags that drive `cd.yaml`) |
| `.github/workflows/codeql.yaml` | Advanced CodeQL for the languages found in the repository, reading `.github/codeql/codeql-config.yml`; off until default setup is off and `CODEQL_SETUP=advanced` |
| `.github/workflows/lint.yaml`, `.github/mega-linter.base.yml` | The shared MegaLinter job `ci.yaml` calls, and the base configuration `.mega-linter.yml` extends |
| `.markdownlint.json` | The shared Markdown rules MegaLinter applies |
| `.yamllint.yml` | The shared YAML rules MegaLinter applies |
| `.coderabbit.yaml` | Shared CodeRabbit settings, layered over the organization's with `inheritance: true` |
| `renovate.json` (*tenant*) | Renovate for `deploy/` image tags and Helm charts only, extending the organization preset; Dependabot keeps everything else |
| `.github/workflows/template-sync.yaml` | Opens the weekly template-sync PR |
| `CLAUDE.md` | `@AGENTS.md` shim |
| `docs/REFERENCE.md` | This reference |
| `scripts/workflow-caller-pin-contract.test.sh` (*tenant*) | Runs in each tenant's required CI and rejects malformed, divergent, or rolled-back reusable-workflow pins, and a version comment that does not name the tag of the pinned commit |
| `scripts/publish-pin-approved.sh`, `scripts/publish-pin-approved.test.sh` (*tenant*) | Checks the minimal direct-action signing job. Existing reusable-workflow callers retain their exact Platform approval checks. The default `ci.yaml` runs the `publish-pin-approved` job and includes it in `ci-required-checks`; this unregistered template runs its tests only. Older tenants that own `ci.yaml` add the job themselves |
| `zizmor.yml` | GitHub Actions pinning policy enforced by the security scan |

**Scaffold-time only (arrives when the repo is created, is removed by `scripts/scaffold.sh`, and is
never re-synced, so a tenant still carrying these from an older sync can delete them for good):**

| File | Purpose |
|---|---|
| `stacks/` | The Go and .NET stack sources the scaffold copies once; the copies are then yours |
| `scripts/scaffold.sh` (+ its test) | One-shot stack and tenancy scaffold; its test scaffolds every combination and checks what each leaves |
| `.github/workflows/validate-stacks.yaml` | Scaffolds each stack as a tenant, then builds, tests, lints, renders `deploy/`, builds the image and checks it serves `GET /` under the restricted container settings |
| `.github/workflows/validate-scaffold.yaml` | Renders `deploy/` and `deploy/dev`, schema-validates every resource, applies the live Platform/shared Kyverno policies, and exercises a pinned Kubernetes API. The live checks prove the template publishes through the pinned signing workflow; Platform still wires the private GHCR pull credential to the tenant identity and cosign-verifying OCI source; and Flux consumes that source while impersonating and targeting the managed `restricted` namespace for both KRO and manual registrations. They then prove the Deployment passes Pod Security `restricted`, the tenant identity can reconcile every rendered kind, and cluster-scoped or interactive privileges remain denied. It gates template PRs, re-validates `main` after every merge, and rechecks upstream drift every day at 06:17 UTC (or on manual dispatch), keeping one tracking issue open while that scheduled check fails on `main`; structural mutation tests keep every layer fail-closed. The workflow no-ops in tenants and is scaffold-time only |
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
.mega-linter.yml
.github/codeql/codeql-config.yml
.releaserc
.gitignore
Dockerfile
README.md
CONTRIBUTING.md
LICENSE
deploy/
.templatesyncignore

# Template scaffolding — dead code in a live application; keep ignored so a
# template-sync never re-introduces it after you delete it.
stacks/
scripts/scaffold.sh
scripts/scaffold.test.sh
.github/workflows/validate-stacks.yaml
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

# Only without --tenancy: the tenant plumbing the scaffold removed.
.github/workflows/cd.yaml
renovate.json
scripts/publish-pin-approved.sh
scripts/publish-pin-approved.test.sh
scripts/workflow-caller-pin-contract.test.sh
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
Each tag triggers `cd.yaml`, which runs the pinned
[`actions/publish-app`](https://github.com/devantler-tech/.github/tree/main/actions/publish-app)
composite action directly in this repository. It builds the image, pins its digest into
`deploy/base/deployment.yaml`, and publishes the entire `deploy/` tree, including both overlays.
The image and manifests are signed as this repository’s own release workflow on its release tag.
The action refuses a tag outside the default branch, a persisted checkout credential, invalid
inputs, changed deployment sources and an occupied version before publication. It verifies the
signatures before exposing release tags. The upstream template itself never publishes.

The required caller-pin check binds the action’s immutable commit to its version tag and rejects
versions below the reviewed floor. The signing-job check retains a tag-only trigger, credential-free
checkout, minimal permissions, serialization and an unskippable publisher. Existing reusable-workflow
callers still require their exact Platform publisher approvals; the direct action uses the tenant’s
own release identity instead. Keep the approval job while migrating existing consumers.

The live envelope check reads Platform’s current KRO and manual tenant definitions. It verifies the
source, namespace, credential, reconciliation and OpenBao boundaries, including a match between the
starter’s own release identity and the generic tenant’s signer rule. Its existing shared-publisher
compatibility cases still reject mutable references, wrong producers, excess or duplicate approvals,
multiple YAML documents and malformed conditional source expressions. New controls also reject a
shared-only rule for the direct publisher and a signer name taken from anywhere except the tenant
name. This source compatibility check establishes no actual publication or deployment.

> **Convention:** the Deployment's container `name` MUST equal the repository
> name — `publish-app` pins the built image digest into the container with that
> name (`app-name: ${{ github.event.repository.name }}` in `cd.yaml`).

## Validate locally

Native required CI also inspects workflow startup failures at the pull-request
head, using only Actions read access. It requires a complete clear snapshot in
addition to successful tenant jobs. Separate workflows still need their own
required checks for failures that happen after that snapshot.

Run these from the repository root. In every platform tenant, and in this template:

```sh
kubectl kustomize deploy/                              # production manifests build
kubectl kustomize deploy/dev                           # dev overlay builds (tenants with deploy/dev)
sh scripts/workflow-caller-pin-contract.test.sh       # portable tenant caller-pin contract (resolves the version-comment tag on github.com and compares it with the pinned commit)
sh scripts/publish-pin-approved.test.sh               # publish-app pin approval check (reads a local approved set, never the network)
actionlint .github/workflows/*                         # workflows parse
```

Additionally, in this template repository. A new tenant starts with these
scaffold-time scripts, but template sync never updates them, so a tenant that
keeps them runs them against stale copies; live tenants delete and ignore them:

```sh
sh scripts/scaffold.test.sh                           # stack and tenancy scaffold, every combination
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

The live tenant-envelope check requires `kro` ownership on the controller-created
Namespace and ServiceAccount; the manual registration retains `ksail` ownership.

The live VPA-floor check additionally needs Kyverno CLI 1.19.1 or later and a
read-only Platform checkout at `.platform` (or `PLATFORM_ROOT`). It evaluates the
Deployment policy locally against a copy of the scaffold in a test namespace;
it does not contact a cluster. Run `sh scripts/platform-vpa-floor.test.sh` with
`kyverno` on `PATH`, or set `KYVERNO_CLI` to the binary's path. The workflow
downloads and checksum-verifies its pinned CLI before this check.
