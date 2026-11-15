// Feature flags through the portable OpenFeature API. New features land behind a
// flag, default-off, are tested in both states, and are switched on only after
// validation. The in-memory provider needs no backend; swap it for flagd or a
// hosted provider without touching call sites.
import {
	InMemoryProvider,
	OpenFeature,
	type Client,
	type Provider
} from '@openfeature/server-sdk';

/** Names this application's feature-flag client. */
export const flagDomain = 'app';

/** A sample flag that gates `exampleFeature`; replace it with your own. */
export const exampleFlag = 'example-feature';

/** Builds an in-memory provider serving the given boolean flag states. */
export function inMemoryProvider(flags: Record<string, boolean>): InMemoryProvider {
	return new InMemoryProvider(
		Object.fromEntries(
			Object.entries(flags).map(([key, on]) => [
				key,
				{
					disabled: false,
					variants: { on: true, off: false },
					defaultVariant: on ? 'on' : 'off'
				}
			])
		)
	);
}

/** Registers the provider under `domain` and returns a client bound to it. */
export async function flagClient(
	domain: string = flagDomain,
	provider: Provider = inMemoryProvider({})
): Promise<Client> {
	await OpenFeature.setProviderAndWait(domain, provider);
	return OpenFeature.getClient(domain);
}

/**
 * Returns the new behaviour when `exampleFlag` is on and the default otherwise.
 * A missing flag or an evaluation error resolves to off, so a flag failure never
 * turns a feature on.
 */
export async function exampleFeature(client: Client): Promise<string> {
	const enabled = await client.getBooleanValue(exampleFlag, false);
	return enabled ? 'new feature output' : 'default output';
}
