# platform-tenant-template

Start a new app for the
[devantler-tech platform](https://github.com/devantler-tech/platform) from this
template. It gives your repository the build, signing, release and deploy plumbing,
so all you add is your app.

The platform calls such an app a **tenant**: it lives in its own repository, and the
platform deploys what that repository publishes. The template holds no application
code and works with any language or framework. After you create a repository from
it, a weekly [template-sync](https://github.com/AndreasAugustin/actions-template-sync)
pull request keeps the shared plumbing up to date.

## Use this template

1. **Create your repository.** Click **"Use this template" → Create a new
   repository**, or run the following, replacing `<tenant>` with your app's name:

   ```sh
   gh repo create devantler-tech/<tenant> --template devantler-tech/platform-tenant-template --private
   gh repo clone devantler-tech/<tenant>
   cd <tenant>
   ```

2. **Rename the placeholder app to your tenant name.** Run
   [`scripts/rename-placeholders.sh`](scripts/rename-placeholders.sh). It uses the
   directory name, or you can pass one: `scripts/rename-placeholders.sh my-tenant`.
   The name must equal the repository name. [What the rename changes](docs/REFERENCE.md#what-the-rename-changes)
   lists everything it touches.
3. **Replace the example with your app:** application code, `Dockerfile`, the
   example stack job in `.github/workflows/ci.yaml`, and `AGENTS.md`.
4. **Protect your own files from the weekly sync** by creating `.templatesyncignore`
   from [the list in the reference](docs/REFERENCE.md#what-the-template-owns-vs-what-you-own).
5. **Register the tenant on the platform.** Follow
   [`platform/docs/TENANTS.md`](https://github.com/devantler-tech/platform/blob/main/docs/TENANTS.md).

Default PR CI always builds the tenant image and renders `deploy/` before merge,
using no secrets or write authority. Keep the `delivery-inputs` job and its entry
in `ci-required-checks` when you replace the example job with your stack's lint,
test, and build commands. This catches the same image and manifest failures in
the pull request that introduced them instead of during release or reconciliation.

Releases need no manual step: [How publishing works](docs/REFERENCE.md#how-publishing-works)
explains how merges to `main` become signed releases that the platform deploys.

## Reference

[`docs/REFERENCE.md`](docs/REFERENCE.md) covers what the rename changes, which files the template
keeps in sync and which are yours, how publishing works, and how to validate the template locally.
