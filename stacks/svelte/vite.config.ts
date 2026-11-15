import adapter from '@sveltejs/adapter-node';
import { sveltekit } from '@sveltejs/kit/vite';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';
import { defineConfig } from 'vitest/config';

export default defineConfig({
	plugins: [
		sveltekit({
			preprocess: vitePreprocess(),
			// adapter-node serves on PORT (deploy/deployment.yaml sets 3000).
			adapter: adapter({ out: 'build' })
		})
	],
	test: {
		include: ['src/**/*.{test,spec}.{js,ts}']
	}
});
