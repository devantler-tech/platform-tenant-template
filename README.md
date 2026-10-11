# platform-tenant-template

Start a new app for the
[devantler-tech platform](https://github.com/devantler-tech/platform) from this
starter. It supplies example Kubernetes manifests and build, signing, release
and deployment plumbing for a tenant repository. It is not a platform installer.

The platform calls such an app a **tenant**: it lives in its own repository, and the
platform deploys what that repository publishes. The supplied [Dockerfile](Dockerfile)
serves a placeholder HTTP page, not a finished application; replace it with your
own app and image build. The starter is language-independent.

## Inspect the scaffold locally

You need Git and [kubectl](https://kubernetes.io/docs/tasks/tools/) with its built-in
Kustomize support. No GitHub token, Kubernetes credentials, cloud account or
running cluster is needed for this first result:

```sh
git clone https://github.com/devantler-tech/platform-tenant-template.git
cd platform-tenant-template
kubectl kustomize deploy/
```

Success is exit 0 with the example resources printed as YAML, including the
Deployment, Service and HTTPRoute. Names and image values are placeholders.
Rendering does not validate every CRD field, deploy an app or prove platform
registration. Do not apply this unmodified scaffold to a cluster.

To improve this upstream starter, follow [CONTRIBUTING.md](CONTRIBUTING.md).
To adopt it as an app, use the separate maintainer steps below.

## Use this template

Creation is currently blocked until [#211](https://github.com/devantler-tech/platform-tenant-template/issues/211)
enables this repository as a GitHub template. Inspecting and contributing above
still work. Once enabled, an authorized maintainer can click **Use this template**
on the repository page, choose the intended owner and private visibility, or use
the CLI route below.

1. **Create your repository.** This is an organization write, not local setup.
   It needs [GitHub CLI](https://cli.github.com/) authentication and permission to
   create a private repository in devantler-tech. Replace `my-tenant` with the
   intended repository name and run only when you intend to create it:

   ```sh
   gh repo create devantler-tech/my-tenant --template devantler-tech/platform-tenant-template --private
   gh repo clone devantler-tech/my-tenant
   cd my-tenant
   ```

2. **Rename the placeholder app to your tenant name.** Run
   [`scripts/rename-placeholders.sh`](scripts/rename-placeholders.sh). It uses the
   directory name, or you can pass one: `scripts/rename-placeholders.sh my-tenant`.
   The name must equal the repository name. [What the rename changes](docs/REFERENCE.md#what-the-rename-changes)
   lists everything it touches. Run it only in your generated app repository,
   never in an upstream contribution checkout. Review `git diff` and run
   `kubectl kustomize deploy/` again; this is still only a local render.
3. **Replace the example with your app:** application code, `Dockerfile`, the
   example stack job in `.github/workflows/ci.yaml`, and `AGENTS.md`.
4. **Protect your own files from the weekly sync.** Tailor the supplied
   [`.templatesyncignore`](.templatesyncignore) and replace the contribution guide
   with your app's process. [The ownership reference](docs/REFERENCE.md#what-the-template-owns-vs-what-you-own)
   explains which files sync may replace. Sync needs the configured GitHub App
   credentials; they are not needed for the public local inspection above.
   Existing tenants must confirm their own ignore file contains `CONTRIBUTING.md`
   before the sync runs. The current workflow merges new ignore entries, but an
   older consumer workflow may not; add and commit the entry yourself if missing.
   If a sync PR is already open, restore your tailored guide and commit the ignore
   entry before merging it: the entry does not undo changes already proposed.
5. **Register the tenant on the platform.** Follow
   [`platform/docs/TENANTS.md`](https://github.com/devantler-tech/platform/blob/main/docs/TENANTS.md).

Default PR CI always builds the tenant image and renders `deploy/` before merge,
using no secrets or write authority. Keep the `delivery-inputs` job and its entry
in `ci-required-checks` when you replace the example job with your stack's lint,
test, and build commands. This catches the same image and manifest failures in
the pull request that introduced them instead of during release or reconciliation.
Keep the `publish-pin-approved` job and its entry too: it holds back a dependency
update that moves the publishing workflow to a revision the platform has not yet
approved for your tenant, so the release it would cut does not fail to deploy.

After authorized App setup and platform registration, eligible Conventional
Commits can produce tags that trigger the signed publishing pipeline. Neither a
local render nor the presence of workflow files proves publication or a live
deployment. [How publishing works](docs/REFERENCE.md#how-publishing-works)
explains the handoff and checks. Release and publication intentionally no-op in
this upstream template repository.

## Reference

[`docs/REFERENCE.md`](docs/REFERENCE.md) covers what the rename changes, which files the template
keeps in sync and which are yours, how publishing works, and how to validate the template locally.

The scaffold is [Apache-2.0 licensed](LICENSE). Upstream community and private
security-reporting routes are in [CONTRIBUTING.md](CONTRIBUTING.md); tenant apps
own their own contribution and disclosure policies.
