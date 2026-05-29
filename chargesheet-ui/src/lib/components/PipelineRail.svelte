<script lang="ts">
	import { goto } from '$app/navigation';
	import { projectsStore } from '$lib/stores/projects.svelte';
	import { connectionStore } from '$lib/stores/connection.svelte';
	import type { Project } from '$lib/api/types';

	type Stage = 'slice' | 'extract' | 'analyze' | 'review';

	let {
		project,
		stage,
		onStage,
		stageProgress,
	}: {
		project: Project;
		stage: Stage;
		onStage: (s: Stage) => void;
		stageProgress: Record<Stage, number>;
	} = $props();

	let switcherOpen = $state(false);

	const STAGES: { key: Stage; n: number; label: string; sub: string }[] = [
		{ key: 'slice',   n: 1, label: 'Slice',   sub: 'Cut annexures from the chargesheet' },
		{ key: 'extract', n: 2, label: 'Extract', sub: 'OCR each slice to markdown' },
		{ key: 'analyze', n: 3, label: 'Analyze', sub: 'Run defence prompts on extracted text' },
		{ key: 'review',  n: 4, label: 'Review',  sub: 'See tokens, cost, slowest jobs' },
	];

	const activeN = $derived(STAGES.find((s) => s.key === stage)?.n ?? 1);

	async function pick(pid: string) {
		switcherOpen = false;
		if (pid === '__all') {
			await goto('/');
		} else {
			await goto(`/projects/${pid}`);
		}
	}
</script>

<div class="flex h-full w-[256px] flex-shrink-0 flex-col border-r border-line bg-panel">
	<!-- Brand mark -->
	<div class="border-b border-line-2 px-[22px] py-[18px] pb-[15px]">
		<div class="flex items-center gap-[9px]">
			<div
				class="grid h-[26px] w-[26px] place-items-center rounded-[6px] bg-navy font-serif text-[13px] font-bold text-white"
				aria-hidden="true"
			>C</div>
			<div class="font-sans text-[12px] font-bold tracking-[1.4px] text-ink">CHARGESHEET</div>
		</div>
	</div>

	<!-- Project switcher -->
	<div class="relative px-4 py-[14px]">
		<div class="mb-[7px] font-sans text-[10px] font-semibold tracking-[1px] text-ink-3">
			CURRENT MATTER
		</div>
		<button
			onclick={() => (switcherOpen = !switcherOpen)}
			class="flex w-full items-center justify-between gap-2 rounded-[9px] bg-card px-3 py-[10px] text-left transition-colors focus:outline-none focus:ring-2 focus:ring-navy/30"
			style="border: 1px solid {switcherOpen ? 'var(--color-navy)' : 'var(--color-line)'};"
		>
			<div class="min-w-0">
				<div class="truncate font-sans text-[13px] font-semibold text-ink">{project.name}</div>
				<div class="truncate font-sans text-[11px] font-medium text-ink-3">
					{project.chargesheet.filename}
				</div>
			</div>
			<span
				class="flex-shrink-0 font-sans text-[13px] text-ink-3 transition-transform duration-150"
				style={switcherOpen ? 'transform: rotate(180deg);' : ''}
				aria-hidden="true"
			>⌄</span>
		</button>

		{#if switcherOpen}
			<div
				class="absolute left-4 right-4 top-[calc(14px+62px)] z-40 overflow-hidden rounded-[11px] border border-line bg-card shadow-[0_10px_30px_rgba(40,35,25,0.16)]"
			>
				{#each projectsStore.projects as p (p.id)}
					<button
						onclick={() => pick(p.id)}
						class="w-full border-b border-line-2 px-[13px] py-[10px] text-left transition-colors hover:bg-navy-soft/50 focus:outline-none focus:ring-2 focus:ring-inset focus:ring-navy/30"
						class:bg-navy-soft={p.id === project.id}
					>
						<div class="font-sans text-[12.5px] font-semibold text-ink">{p.name}</div>
						<div class="mt-px font-sans text-[10.5px] font-medium text-ink-3">
							{p.chargesheet.filename} · {p.chargesheet.page_count}p
						</div>
					</button>
				{/each}
				<button
					onclick={() => pick('__all')}
					class="w-full bg-panel px-[13px] py-[10px] text-left font-sans text-[12px] font-semibold text-navy hover:bg-navy-soft/50 focus:outline-none focus:ring-2 focus:ring-inset focus:ring-navy/30"
				>
					← All matters
				</button>
			</div>
		{/if}
	</div>

	<!-- Pipeline stepper -->
	<div class="flex-1 overflow-y-auto px-4 pb-4 pt-[6px]">
		<div class="m-[4px_6px_10px] font-sans text-[10px] font-semibold tracking-[1px] text-ink-3">
			PIPELINE
		</div>
		<div class="relative">
			<!-- Connector line behind circles -->
			<div class="absolute bottom-4 left-[18px] top-4 w-[2px] bg-line"></div>

			{#each STAGES as s (s.key)}
				{@const isActive = s.key === stage}
				{@const isDone = s.n < activeN}
				{@const prog = stageProgress[s.key] ?? 0}
				<button
					onclick={() => onStage(s.key)}
					class="relative mb-0.5 flex w-full gap-3 rounded-[9px] px-[7px] py-[9px] text-left transition-colors focus:outline-none focus:ring-2 focus:ring-navy/30"
					class:bg-navy-soft={isActive}
				>
					<div
						class="z-10 grid h-[26px] w-[26px] flex-shrink-0 place-items-center rounded-full font-sans text-[12px] font-bold transition-all duration-150"
						class:bg-navy={isActive}
						class:text-white={isActive || isDone}
						class:bg-ok={isDone && !isActive}
						class:bg-card={!isActive && !isDone}
						class:text-ink-2={!isActive && !isDone}
						style={!isActive && !isDone ? 'border: 1.5px solid var(--color-line);' : ''}
					>
						{#if isDone}✓{:else}{s.n}{/if}
					</div>
					<div class="min-w-0 flex-1">
						<div
							class="font-sans text-[13px]"
							class:font-bold={isActive}
							class:text-navy={isActive}
							class:font-semibold={!isActive}
							class:text-ink={!isActive}
						>{s.label}</div>
						<div class="mt-px font-sans text-[10.5px] font-medium leading-[1.3] text-ink-3">
							{s.sub}
						</div>
						{#if isActive || isDone || prog > 0}
							<div class="mt-[7px] h-[3px] overflow-hidden rounded-full bg-line">
								<div
									class="h-full rounded-full transition-[width] duration-300"
									class:bg-ok={isDone}
									class:bg-navy={!isDone}
									style="width: {prog * 100}%;"
								></div>
							</div>
						{/if}
					</div>
				</button>
			{/each}
		</div>
	</div>

	<!-- Footer: daemon status -->
	<div class="flex items-center justify-between border-t border-line-2 px-[18px] py-[13px]">
		<div class="flex items-center gap-[7px] font-sans text-[11px] font-semibold text-ink-2">
			<span
				class="h-[7px] w-[7px] rounded-full"
				class:bg-ok={connectionStore.online}
				class:bg-err={!connectionStore.online}
			></span>
			Daemon {connectionStore.online ? 'connected' : 'offline'}
		</div>
	</div>
</div>
