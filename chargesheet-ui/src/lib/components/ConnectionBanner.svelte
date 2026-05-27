<script lang="ts">
	import { connectionStore } from '$lib/stores/connection.svelte';
</script>

{#if !connectionStore.online}
	<div
		class="fixed inset-x-0 top-0 z-40 border-b border-amber-300 bg-amber-100 px-4 py-2 text-center text-sm text-amber-900"
		role="alert"
	>
		<span class="font-medium">Cannot reach the daemon.</span> Reconnecting…
	</div>
{/if}
