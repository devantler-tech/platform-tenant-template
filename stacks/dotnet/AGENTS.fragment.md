- .NET 11, ASP.NET Core minimal API (`src/Example`)
- [OpenFeature](https://openfeature.dev/) feature flags (`src/Example/FeatureFlags.cs`), in-memory
  until you choose a provider; new features land behind a flag, default-off
- xUnit v3 tests (`tests/Example.Tests`), hosting the app in memory with `WebApplicationFactory`

## Validation

CI builds and tests the solution. Every project builds with `AnalysisMode=All`,
`EnforceCodeStyleInBuild` and `TreatWarningsAsErrors`, so analyzer and style findings fail the
build. Locally:

```sh
dotnet build
dotnet test
```

`global.json` pins the SDK feature band; move it and every `<TargetFramework>` together.
