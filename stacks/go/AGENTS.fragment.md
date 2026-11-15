- Go, standard library `net/http` server (`main.go`, `internal/server`)
- [OpenFeature](https://openfeature.dev/) feature flags (`internal/featureflag`), in-memory until
  you choose a provider; new features land behind a flag, default-off
- `go test` with table-driven tests; golangci-lint v2 (`.golangci.yml`)

## Validation

CI runs the shared Go validator (build, test, lint, security and coverage). Locally:

```sh
go build ./...
go test -race ./...
golangci-lint run
```

`.golangci.yml` lets non-test code import only the standard library, OpenFeature and this
module, so add each new dependency to its `depguard` allowlist.
