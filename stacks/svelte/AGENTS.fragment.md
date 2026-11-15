- TypeScript, SvelteKit 3 and Svelte 5 with `adapter-node` (`src/routes`)
- [OpenFeature](https://openfeature.dev/) feature flags (`src/lib/server/flags.ts`), in-memory until
  you choose a provider; new features land behind a flag, default-off
- Vitest unit tests, svelte-check and ESLint (`eslint.config.js`)

## Validation

CI installs, lints, type-checks, tests and builds. Locally, with the Node major in `.node-version`:

```sh
npm ci
npm run lint
npm run check
npm test
npm run build
```

Import application modules through the `#lib` alias with an explicit `.js` extension, for example
`#lib/server/flags.js`.
