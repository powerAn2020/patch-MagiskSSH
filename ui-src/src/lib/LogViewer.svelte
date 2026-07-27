<script lang="ts">
    import { onMount, onDestroy } from "svelte";
    import { api } from "./ksu";
    import { _ } from "svelte-i18n";
    import { Terminal } from "lucide-svelte";

    const POLL_INTERVAL_MS = 3000;
    const MAX_LINES = 200;

    let logs: string[] = $state([]);
    let logsContainer: HTMLElement;
    let autoScroll = $state(true);
    let timer: ReturnType<typeof setInterval> | null = null;
    let nextLine = 1; // 下次从第几行开始读（1-based）

    function appendLines(newLines: string[]) {
        if (newLines.length === 0) return;
        logs = [...logs, ...newLines].slice(-MAX_LINES);
        if (autoScroll && logsContainer) {
            requestAnimationFrame(() => {
                logsContainer.scrollTop = logsContainer.scrollHeight;
            });
        }
    }

    async function poll() {
        try {
            const res = await api("read_log_from", String(nextLine));
            const outer = JSON.parse(res.stdout);
            const b64 = outer.stdout || "";
            if (!b64.trim()) return;

            // 后端返回 base64 编码的 "total\nlog_lines..."
            const raw = decodeURIComponent(escape(atob(b64.trim())));
            const lines = raw.split("\n");

            if (lines.length === 0 || (lines.length === 1 && lines[0] === ""))
                return;

            const total = parseInt(lines[0], 10);
            if (isNaN(total)) return;

            // 文件被清空（clear_log 后 total 归 0），重置偏移
            if (total === 0 || total < nextLine - 1) {
                nextLine = 1;
                logs = []; // 也重置本地日志显示
                return;
            }

            const newLines = lines.slice(1).filter(Boolean);
            nextLine = total + 1;
            appendLines(newLines);
        } catch (e) {
            console.error("[Logs] Poll failed", e);
        }
    }

    function clearLogs() {
        logs = [];
        nextLine = 1;
        api("clear_log");
    }

    onMount(() => {
        poll();
        timer = setInterval(poll, POLL_INTERVAL_MS);
    });

    onDestroy(() => {
        if (timer !== null) clearInterval(timer);
    });

    function handleScroll() {
        if (!logsContainer) return;
        const { scrollTop, scrollHeight, clientHeight } = logsContainer;
        autoScroll = scrollHeight - scrollTop - clientHeight < 10;
    }
</script>

<div
    class="bg-slate-950 shadow-sm rounded-xl border border-slate-800 overflow-hidden flex flex-col h-[400px]"
>
    <div
        class="flex items-center justify-between px-4 py-3 bg-slate-900 border-b border-slate-800"
    >
        <div class="flex items-center gap-2">
            <Terminal class="w-4 h-4 text-emerald-400" />
            <h2 class="text-sm font-semibold text-slate-200">
                {$_("app.logs.title")}
            </h2>
            {#if autoScroll}
                <span class="flex h-2 w-2 relative ml-2">
                    <span
                        class="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"
                    ></span>
                    <span
                        class="relative inline-flex rounded-full h-2 w-2 bg-emerald-500"
                    ></span>
                </span>
            {/if}
        </div>
        <button
            onclick={clearLogs}
            class="text-xs font-medium text-slate-400 hover:text-white transition-colors px-2 py-1 rounded"
        >
            {$_("app.logs.btn_clear")}
        </button>
    </div>

    <div
        bind:this={logsContainer}
        onscroll={handleScroll}
        class="flex-1 p-4 overflow-y-auto font-mono text-xs leading-5 text-emerald-400/90 whitespace-pre-wrap selection:bg-emerald-900/50"
    >
        {#if logs.length === 0}
            <p class="text-slate-600 italic">Waiting for logs...</p>
        {:else}
            {#each logs as logRow}
                <div class="break-all">{logRow}</div>
            {/each}
        {/if}
    </div>
</div>
