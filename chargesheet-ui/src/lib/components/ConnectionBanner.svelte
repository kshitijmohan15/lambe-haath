<script lang="ts">
	import { connectionStore } from '$lib/stores/connection.svelte';
</script>

{#if !connectionStore.online}
	<div
		class="border-b border-err bg-[rgba(162,59,46,0.06)] px-6 py-2 font-sans text-[12.5px] text-err"
		role="alert"
	>
		<span class="font-semibold">Cannot reach the daemon.</span> Reconnecting…
	</div>
{/if}
