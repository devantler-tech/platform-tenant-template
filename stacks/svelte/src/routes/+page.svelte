<script lang="ts">
	import type { PageProps } from './$types';

	let { data }: PageProps = $props();
</script>

<svelte:head>
	<title>app</title>
</svelte:head>

<h1>Replace this placeholder with your app.</h1>
<p>{data.message}</p>
