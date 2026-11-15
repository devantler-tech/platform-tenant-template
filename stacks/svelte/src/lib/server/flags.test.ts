import { describe, expect, it } from 'vitest';
import { exampleFeature, exampleFlag, flagClient, inMemoryProvider } from './flags.js';

type FlagCase = { name: string; flags: Record<string, boolean>; want: string };

const cases: FlagCase[] = [
	{ name: 'flag on serves the new path', flags: { [exampleFlag]: true }, want: 'new feature output' },
	{ name: 'flag off serves the default path', flags: { [exampleFlag]: false }, want: 'default output' },
	{ name: 'missing flag defaults to off', flags: {}, want: 'default output' }
];

describe('exampleFeature', () => {
	it.each(cases)('$name', async ({ name, flags, want }) => {
		const client = await flagClient(`flags-test-${name}`, inMemoryProvider(flags));

		expect(await exampleFeature(client)).toBe(want);
	});
});
