# Contributing to the application template

Help make starting an application safer and easier: improve a confusing explanation,
an example manifest, a stack under `stacks/` or a focused scaffold check. Discuss
substantial work in an
[issue](https://github.com/devantler-tech/application-template/issues) first.
This guide is for the **public upstream template**, not an application's own repository.
Generated repositories own this guide and should replace it with their process.
Their own `.templatesyncignore` must contain `CONTRIBUTING.md` to protect it.
New projects include that entry. The current template sync workflow merges new
ignore entries into consumers; older workflows may not. Before the sync runs,
confirm the entry is present in your own ignore file or add and commit it yourself.
If a sync PR is already open, restore your tailored guide and commit the ignore
entry before merging it; the entry does not undo changes already proposed.
See the [ownership reference](docs/REFERENCE.md#what-the-template-owns-vs-what-you-own).

Do not put credentials, private application details or sensitive vulnerabilities in
a public issue or PR. Use this repository's private
[Report a vulnerability](https://github.com/devantler-tech/application-template/security/advisories/new)
form for sensitive security reports.

## Make a first upstream change

You need Git, a POSIX shell and standard Unix tools, kubectl with built-in
Kustomize, [Mike Farah's yq v4](https://mikefarah.gitbook.io/yq/), jq,
[actionlint](https://github.com/rhysd/actionlint), and a working Docker engine for
the image check. Docker may download the public base image. To change a stack,
also install its toolchain: a Go toolchain meeting `stacks/go/go.mod` and golangci-lint v2.14, or the
.NET SDK `stacks/dotnet/global.json` names. No App key, cloud account, private
tenant checkout or production Kubernetes context is required.

Fork `devantler-tech/application-template` on GitHub, replace `YOUR-LOGIN`
with your login, and work from your fork:

```sh
git clone https://github.com/YOUR-LOGIN/application-template.git
cd application-template
git switch -c docs/first-contribution
```

Make a small wording improvement in `README.md`. Keep the upstream placeholders;
do not scaffold, rename or register this checkout as an application. From the
repository root, run the local baseline and all template-only contract checks listed under
[Validate locally](docs/REFERENCE.md#validate-locally), then:

```sh
docker build --tag tenant-delivery-check .
git diff --check
```

Every command must exit 0. Rendering prints placeholder manifests; actionlint
and whitespace checks normally print nothing on success. Contract tests must
report their successful assertions, not a skipped prerequisite. The scaffold
and rename tests operate on temporary copies, including their render, so your
upstream checkout is not changed. The Docker command builds a local placeholder image;
it does not publish it or contact a Kubernetes cluster.

These local contract tests use fixtures and structural checks. They do **not**
replace native CI's schema validation, live-policy evaluation or disposable
Kubernetes admission/RBAC checks in
[validate-scaffold.yaml](.github/workflows/validate-scaffold.yaml). The `*.test.sh`
runtime checks without `contract` in their names include cluster-facing paths;
do not point them at production for this contribution exercise. Use the
reference's explicit command list, not a loop over every test script.

A change under `stacks/` must keep the stack building, testing and linting where it
lives, for example `go test ./...` and `golangci-lint run` in `stacks/go`, or
`dotnet build Example.slnx` and `dotnet test --solution Example.slnx` in `stacks/dotnet`.
[validate-stacks.yaml](.github/workflows/validate-stacks.yaml) then scaffolds each stack as
a tenant and checks its image serves `GET /`.

## Submit your change

Review the diff, configure commit signing, and stage explicit changed paths.
For the README-only first change above:

```sh
git add README.md
git commit -S -m "docs: clarify application onboarding"
git push -u origin docs/first-contribution
```

Open a **draft** PR to `devantler-tech/application-template:main` using the
inherited [PR template](https://github.com/devantler-tech/.github/blob/main/.github/PULL_REQUEST_TEMPLATE.md).
Use a Conventional Commit title. Keep Why/What focused on the reader-facing
problem and outcome, link the issue for substantial work, and put detailed
validation in a comment or check summary. Disclose AI assistance when used.
Address findings; required native CI and a substantive review at the exact
current head must pass before merge.

Follow the inherited [code of conduct](https://github.com/devantler-tech/.github/blob/main/.github/CODE_OF_CONDUCT.md)
and preserve the [Apache-2.0 license](LICENSE). App installation, private tenant
creation, signing/publication credentials and platform registration are
maintainer procedures, not prerequisites for this local contribution path.
