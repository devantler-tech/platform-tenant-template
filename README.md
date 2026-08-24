# platform-tenant-template

A template for **GitOps tenants** on the
[devantler-tech platform](https://github.com/devantler-tech/platform) — an
application that runs on the platform from its own repository. The template ships
the shared, **framework-agnostic** CI/CD plumbing (build → signed publish →
release) and keeps it current in every tenant via
[template-sync](https://github.com/AndreasAugustin/actions-template-sync).

It is intentionally **stack-neutral**: it carries no application code or
language-specific tooling. Bring your own stack (any language, any framework) and
fill in the scaffolding.

## Use this template

1. Click **"Use this template" → Create a new repository** (or
   `gh repo create devantler-tech/<tenant> --template devantler-tech/platform-tenant-template --private`).
2. **Rename the placeholders** in `deploy/` to your tenant name — run
   [`scripts/rename-placeholders.sh`](scripts/rename-placeholders.sh) (defaults to
   the repo directory name, or pass one: `scripts/rename-placeholders.sh my-tenant`).
   It rewrites the `app`, `REPLACE_ME`, and `replace-me` placeholders
   consistently, including the container name, Vault role, and ServiceAccount.
   Those values **must** equal the repo name (see the convention below). The
   helper preserves the `app.kubernetes.io/name` label *keys*, CloudNativePG's
   literal `-app` secret suffix, and the `openbao` SecretStore name. (Doing this
   by hand is easy to get half-wrong.) It's a one-shot helper — delete it once
   adopted.
   The example route is renamed for both environments: `<tenant>.platform.lan`
   locally and `<tenant>.platform.devantler.tech` in production. Keep both in
   `deploy/httproute.yaml`; add any custom domains beside them. Each Platform
   Gateway attaches only the hostnames its listener serves.
   The route also publishes a tile to the Platform Homepage. The helper updates
   its name, production URL, and pod selector; tailor the tile's description,
   group, and icon annotations after the rename to describe your app.
3. Replace the rest of the scaffolding with your app: application code,
   `Dockerfile`, the example stack job in `ci.yaml`, and fill in `AGENTS.md`.
4. Create `.templatesyncignore` (see below).
5. Register the tenant on the platform — follow
   [`platform/docs/TENANTS.md`](https://github.com/devantler-tech/platform/blob/main/docs/TENANTS.md).

Default PR CI always builds the tenant image and renders `deploy/` before merge,
using no secrets or write authority. Keep the `delivery-inputs` job and its entry
in `ci-required-checks` when you replace the example job with your stack's lint,
test, and build commands. This catches the same image and manifest failures in
the pull request that introduced them instead of during release or reconciliation.

## What the template owns vs. what you own

template-sync overwrites the files the template **owns** and never touches the
files **you own**. Declare the files you own in **`.templatesyncignore`** (same
syntax as `.gitignore`). template-sync only ever brings over files that exist in
this template, so you only need to ignore the scaffolding files below — not your
app code.

**Owned by the template (kept in sync — do not edit in your tenant):**

| File | Purpose |
|---|---|
| `.github/workflows/cd.yaml` | On a `v*` tag, calls `publish-app.yaml` to build, digest-pin, push, and **cosign-sign** the image + manifests OCI artifact |
| `.github/workflows/release.yaml` | semantic-release on `main` (cuts the `v*` tags that drive `cd.yaml`) |
| `.github/workflows/template-sync.yaml` | Opens the weekly template-sync PR |
| `.github/workflows/sync-labels.yaml` | Syncs the repo's issue/PR labels from the canonical label set |
| `CLAUDE.md` | `@AGENTS.md` shim |
| `scripts/workflow-caller-pin-contract.test.sh` | Runs in each tenant's required CI and rejects malformed, divergent, or rolled-back reusable-workflow pins |
| `zizmor.yml` | GitHub Actions pinning policy enforced by the security scan |

**Scaffold-time only (arrives when the repo is created — never re-synced, so a
tenant still carrying these from an older sync can delete them for good):**

| File | Purpose |
|---|---|
| `.github/workflows/validate-scaffold.yaml` | Renders `deploy/`, schema-validates every resource, applies the live Platform/shared Kyverno policies, and exercises a pinned Kubernetes API. The live checks prove the template publishes through the pinned signing workflow; Platform still wires the private GHCR pull credential to the tenant identity and cosign-verifying OCI source; and Flux consumes that source while impersonating and targeting the managed `restricted` namespace for both KRO and manual registrations. They then prove the Deployment passes Pod Security `restricted`, the tenant identity can reconcile every rendered kind, and cluster-scoped or interactive privileges remain denied. It gates template PRs and rechecks upstream drift every Monday at 06:17 UTC (or on manual dispatch); structural mutation tests keep every layer fail-closed. The workflow no-ops in tenants and is scaffold-time only |
| `scripts/rename-placeholders.sh` (+ its test) | One-shot rename of the placeholder app to your tenant name |
| `scripts/agent-instructions.test.sh` | Fails closed if the one-time agent scaffold loses its ownership, bot, external-code, exact-head review, or user-path evaluation boundaries |
| `scripts/workflow-caller-contract.test.sh` | Keeps the portable caller-pin contract wired into tenant CI while validating template-only publisher, release, ownership, and scaffold invariants |
| `scripts/tenant-ci-contract.test.sh` | Keeps default tenant PR CI least-privilege and fail-closed over both the image build and rendered manifests |
| `scripts/pod-security-admission*.test.sh` | Proves the rendered Deployment is accepted at Pod Security `restricted` while unsafe mutations are denied, and pins that live gate against structural bypasses |
| `scripts/tenant-rbac*.test.sh` | Proves the Platform tenant reconciliation identity can manage every rendered scaffold resource while cluster-scoped and interactive privileges stay denied |
| `scripts/platform-tenant-envelope*.test.sh` | Binds the template's signed publisher and those workload-level models to Platform's live KRO and manual tenant registrations: private GHCR pull identity, cosign-verifying OCI source, managed Pod Security namespace, `tenant-edit` ServiceAccount binding, Flux source/impersonation/target namespace, and the exact OpenBao policy and Kubernetes-auth role that let the renamed tenant read and seed only its own app secrets |
| `scripts/platform-network-floor*.test.sh` | Binds Platform's generated default-deny, DNS, and standard NetworkPolicy floor to the scaffold's required Gateway, namespace, CNPG, Kubernetes API, and DNS paths |
| `scripts/platform-vpa-floor*.test.sh` | Keeps the scaffold's initial CPU request at or above Platform's generated Deployment VPA floor, with live-policy and mutation coverage |

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

`release.yaml` turns Conventional-Commit merges to `main` into `vX.Y.Z` tags.
Each tag triggers `cd.yaml`, which calls the platform's
[`publish-app.yaml`](https://github.com/devantler-tech/actions/blob/main/.github/workflows/publish-app.yaml)
reusable workflow to build the image, **pin its digest into
`deploy/deployment.yaml`**, push the manifests as an OCI artifact, and
**cosign-sign** both. The platform's `OCIRepository` verifies that signature, so
only artifacts from this trusted workflow are reconciled.

> **Convention:** the Deployment's container `name` MUST equal the repository
> name — `publish-app` pins the built image digest into the container with that
> name (`app-name: ${{ github.event.repository.name }}` in `cd.yaml`).

## Validate locally

```sh
kubectl kustomize deploy/                              # manifests build
sh scripts/rename-placeholders.test.sh                # onboarding contract
sh scripts/agent-instructions.test.sh                 # agent safety contract
sh scripts/workflow-caller-pin-contract.test.sh       # portable tenant caller-pin contract
sh scripts/workflow-caller-contract.test.sh           # template-only caller/scaffold contract
sh scripts/tenant-ci-contract.test.sh                 # tenant delivery-input CI contract
sh scripts/pod-security-admission-contract.test.sh    # Pod Security workflow contract
sh scripts/tenant-rbac-contract.test.sh               # Platform tenant RBAC workflow contract
sh scripts/platform-tenant-envelope-contract.test.sh  # live Platform tenant-envelope contract
sh scripts/platform-network-floor-contract.test.sh    # generated Platform network-floor contract
sh scripts/platform-vpa-floor-contract.test.sh        # generated Platform VPA-floor contract
actionlint .github/workflows/*                         # workflows parse
```
