import svelte from 'eslint-plugin-svelte';
import tseslint from 'typescript-eslint';

export default tseslint.config(
	...tseslint.configs.strict,
	...svelte.configs.recommended,
	{
		ignores: ['build/', '.svelte-kit/', 'node_modules/']
	},
	{
		files: ['**/*.svelte', '**/*.svelte.ts', '**/*.svelte.js'],
		languageOptions: {
			parserOptions: {
				parser: tseslint.parser
			}
		}
	}
);
