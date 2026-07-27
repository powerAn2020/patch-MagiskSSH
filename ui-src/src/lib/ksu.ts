import * as kernelsu from 'kernelsu';

const isMock = import.meta.env.DEV;
const DEBUG_STORAGE_KEY = 'magisk_ssh_debug_enabled';

// --- Debug mode --------------------------------------------------------------
// 默认从 localStorage 读取，做持久化
import { writable } from 'svelte/store';

// 初始值逻辑：localStorage 优先，开发模式默认开启（如果没存过）
const storedDebug = localStorage.getItem(DEBUG_STORAGE_KEY);
const initialDebug = storedDebug !== null ? storedDebug === 'true' : isMock;

export const debugEnabled = writable(initialDebug);

export function toggleDebug(): void {
    debugEnabled.update((v) => {
        const next = !v;
        localStorage.setItem(DEBUG_STORAGE_KEY, String(next));
        console.trace(`[KSU] Debug mode → ${next ? 'ON' : 'OFF'}`);
        return next;
    });
}

let _isDebug = initialDebug;
debugEnabled.subscribe((v) => (_isDebug = v));

function debugLog(label: string, ...args: unknown[]): void {
    if (!_isDebug) return;
    const ts = new Date().toISOString().slice(11, 23); // HH:mm:ss.mmm
    console.groupCollapsed(`%c[KSU ${ts}] ${label}`, 'color:#4fc3f7;font-weight:bold', ...args);
    console.trace('call stack');
    console.groupEnd();
}

// --- Module path resolution via ksu.moduleInfo() ----------------------------

let cachedModDir: string | null = null;

function getModDir(): string {
    if (cachedModDir) return cachedModDir;
    if (isMock) {
        cachedModDir = '/data/adb/modules/MagiskSSH';
        return cachedModDir;
    }
    try {
        const info = kernelsu.moduleInfo();
        // moduleInfo() returns a JSON string, e.g.:
        // {"moduleDir":"/data/adb/modules/ssh","id":"ssh",...}
        const parsed = JSON.parse(info) as { moduleDir?: string };
        cachedModDir = (parsed.moduleDir ?? '').trim() || '/data/adb/modules/MagiskSSH';
    } catch {
        cachedModDir = '/data/adb/modules/MagiskSSH';
    }
    return cachedModDir;
}

function getApiScript(): string {
    return `${getModDir()}/scripts/api.sh`;
}

// --- exec wrapper (blocking, for quick operations) ---------------------------

export async function exec(cmd: string): Promise<{ errno: number; stdout: string; stderr: string }> {
    debugLog('exec ▶', { cmd });
    const t0 = performance.now();
    if (isMock) {
        console.log(`[Mock KSU Exec]: ${cmd}`);
        const result = mockExec(cmd);
        debugLog('exec ◀ (mock)', { ...result, ms: +(performance.now() - t0).toFixed(1) });
        return result;
    }
    const result = await kernelsu.exec(cmd);
    debugLog('exec ◀', { ...result, ms: +(performance.now() - t0).toFixed(1) });
    return result;
}

// High-level: call api.sh <action> [args...]
export async function api(action: string, ...args: string[]): Promise<{ errno: number; stdout: string; stderr: string }> {
    debugLog('api ▶', { action, args });
    const t0 = performance.now();
    const cmd = `sh ${getApiScript()} ${action} ${args.join(' ')}`.trim();
    const result = await exec(cmd);
    debugLog('api ◀', { action, ms: +(performance.now() - t0).toFixed(1), result });
    return result;
}

// High-level: call api.sh <action> and pipe base64-encoded stdin content
export async function apiWithStdin(action: string, content: string): Promise<{ errno: number; stdout: string; stderr: string }> {
    debugLog('apiWithStdin ▶', { action, contentLength: content.length });
    const t0 = performance.now();
    const b64 = btoa(unescape(encodeURIComponent(content)));
    const cmd = `echo '${b64}' | sh ${getApiScript()} ${action}`;
    const result = await exec(cmd);
    debugLog('apiWithStdin ◀', { action, ms: +(performance.now() - t0).toFixed(1), result });
    return result;
}

// --- spawn wrapper (non-blocking, for streaming) ------------------------------

export function spawn(
    cmd: string,
    args: string[],
    onData: (data: string) => void,
    onError: (err: string) => void,
    onExit: (code: number) => void
) {
    debugLog('spawn ▶', { cmd, args });
    if (isMock) {
        console.log(`[Mock KSU Spawn]: ${cmd} ${args.join(' ')}`);
        const timer = setInterval(
            () => {
                const line = `[${new Date().toLocaleTimeString()}] Mock sshd log: Connection from 192.168.1.${Math.floor(Math.random() * 255)}\n`;
                debugLog('spawn data (mock)', line.trim());
                onData(line);
            },
            2000
        );
        setTimeout(() => {
            clearInterval(timer);
            debugLog('spawn exit (mock)', { code: 0 });
            onExit(0);
        }, 60000);
        return () => clearInterval(timer);
    }

    const child = kernelsu.spawn(cmd, args);

    child.stdout.on('data', (chunk: string) => {
        debugLog('spawn stdout', chunk.trim());
        onData(chunk);
    });
    child.stderr.on('data', (chunk: string) => {
        debugLog('spawn stderr', chunk.trim());
        onError(chunk);
    });
    child.on('exit', (code: number) => {
        debugLog('spawn exit', { code });
        onExit(code);
    });

    return () => {
        debugLog('spawn kill', { cmd });
        // kernelsu ChildProcess has no kill(), so we pkill the process
        kernelsu.exec(`pkill -f "${cmd}"`);
    };
}

// High-level: spawn api.sh tail_log (non-blocking log stream)
export function spawnLogTail(
    onData: (data: string) => void,
    onError: (err: string) => void,
    onExit: (code: number) => void
) {
    return spawn('sh', [getApiScript(), 'tail_log'], onData, onError, onExit);
}

// --- Mock responses for dev/PC testing ---------------------------------------

function mockExec(cmd: string): { errno: number; stdout: string; stderr: string } {
    if (cmd.includes('status')) {
        return { errno: 0, stdout: '{"errno":0,"stdout":"{\\"running\\":true,\\"pid\\":\\"1234\\",\\"port\\":\\"22\\"}","stderr":""}', stderr: '' };
    }
    if (cmd.includes('start')) {
        return { errno: 0, stdout: '{"errno":0,"stdout":"sshd started (pid 1234)","stderr":""}', stderr: '' };
    }
    if (cmd.includes('stop')) {
        return { errno: 0, stdout: '{"errno":0,"stdout":"sshd stopped","stderr":""}', stderr: '' };
    }
    if (cmd.includes('read_config')) {
        const cfg = [
            'Port 22',
            'PermitRootLogin yes',
            'PasswordAuthentication no',
            'PubkeyAuthentication yes',
            'AuthorizedKeysFile .ssh/authorized_keys',
            'Subsystem sftp /usr/libexec/sftp-server',
        ].join('\n');
        const b64 = btoa(unescape(encodeURIComponent(cfg)));
        return { errno: 0, stdout: `{"errno":0,"stdout":"${b64}","stderr":""}`, stderr: '' };
    }
    if (cmd.includes('read_keys')) {
        const keys = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample1234567890 user@device\nssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgExample admin@workstation';
        return { errno: 0, stdout: `{"errno":0,"stdout":"${keys.replace(/\n/g, '\\n')}","stderr":""}`, stderr: '' };
    }
    if (cmd.includes('read_log_from')) {
        const logLines = Array.from({ length: 5 }, (_, i) => `[mock] sshd log line ${i + 1}`).join('\n');
        const content = `10\n${logLines}`;
        const b64 = btoa(unescape(encodeURIComponent(content)));
        return {
            errno: 0,
            stdout: `{"errno":0,"stdout":"${b64}","stderr":""}`,
            stderr: '',
        };
    }
    if (cmd.includes('read_log')) {
        const logLines = Array.from({ length: 10 }, (_, i) => `[mock] sshd log line ${i + 1}`).join('\n');
        const b64 = btoa(unescape(encodeURIComponent(logLines)));
        return {
            errno: 0,
            stdout: `{"errno":0,"stdout":"${b64}","stderr":""}`,
            stderr: '',
        };
    }
    if (cmd.includes('get_ip')) {
        return { errno: 0, stdout: '{"errno":0,"stdout":"192.168.1.100","stderr":""}', stderr: '' };
    }
    if (cmd.includes('get_settings')) {
        return {
            errno: 0,
            stdout: '{"errno":0,"stdout":"{\\"autostart\\":false,\\"keep_data\\":true}","stderr":""}',
            stderr: '',
        };
    }
    if (cmd.includes('set_settings')) {
        return { errno: 0, stdout: '{"errno":0,"stdout":"Settings updated","stderr":""}', stderr: '' };
    }
    return { errno: 0, stdout: '{"errno":0,"stdout":"OK","stderr":""}', stderr: '' };
}
