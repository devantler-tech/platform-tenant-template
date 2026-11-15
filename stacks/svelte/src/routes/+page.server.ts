import { exampleFeature, flagClient } from '#lib/server/flags.js';
import type { PageServerLoad } from './$types';

// The platform's liveness and readiness probes call GET /. Keep it answering, or
// move the probes in deploy/deployment.yaml with it.
export const load: PageServerLoad = async () => {
	return { message: await exampleFeature(await flagClient()) };
};
