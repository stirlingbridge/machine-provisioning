/**
 * Web Shell Example — browser-side key management, JWT signing, interactive
 * terminal, and programmatic command execution over ttyd WebSocket.
 *
 * Dependencies: xterm.js and xterm-addon-fit (loaded from CDN in index.html).
 * No build step required.
 */

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let keyPair = null;   // { publicKey: CryptoKey, privateKey: CryptoKey }
let publicPem = '';
let terminal = null;
let termSocket = null;
const STORAGE_KEY = 'web-shell-keypair';

// ---------------------------------------------------------------------------
// DOM refs
// ---------------------------------------------------------------------------

const $ = (id) => document.getElementById(id);

const ui = {
    btnGenerate:    $('btn-generate'),
    btnExportPub:   $('btn-export-pub'),
    btnSaveKeys:    $('btn-save-keys'),
    btnLoadKeys:    $('btn-load-keys'),
    keyStatus:      $('key-status'),
    publicKeyPem:   $('public-key-pem'),
    host:           $('host'),
    jwtLifetime:    $('jwt-lifetime'),
    btnConnect:     $('btn-connect'),
    btnDisconnect:  $('btn-disconnect'),
    connStatus:     $('conn-status'),
    termContainer:  $('terminal-container'),
    execCmd:        $('exec-cmd'),
    btnExec:        $('btn-exec'),
    execStatus:     $('exec-status'),
    execOutput:     $('exec-output'),
};

// ---------------------------------------------------------------------------
// Utility: status helpers
// ---------------------------------------------------------------------------

function setStatus(el, cls, msg) {
    el.textContent = msg;
    el.className = 'status ' + cls;
}

// ---------------------------------------------------------------------------
// 1. Key Management (Web Crypto — Ed25519)
// ---------------------------------------------------------------------------

/**
 * Generate an Ed25519 key pair using the Web Crypto API.
 * Ed25519 support: Chrome 113+, Firefox 130+, Safari 17+.
 */
async function generateKeyPair() {
    try {
        keyPair = await crypto.subtle.generateKey('Ed25519', true, ['sign', 'verify']);
        publicPem = await exportPublicKeyPem(keyPair.publicKey);
        ui.publicKeyPem.value = publicPem;
        setStatus(ui.keyStatus, 'ok', 'Key pair generated.');
    } catch (e) {
        setStatus(ui.keyStatus, 'err', 'Failed: ' + e.message +
            '. Ed25519 requires Chrome 113+, Firefox 130+, or Safari 17+.');
    }
}

/** Export a CryptoKey (public, Ed25519) to PEM format. */
async function exportPublicKeyPem(key) {
    const spki = await crypto.subtle.exportKey('spki', key);
    const b64 = btoa(String.fromCharCode(...new Uint8Array(spki)));
    const lines = b64.match(/.{1,64}/g).join('\n');
    return '-----BEGIN PUBLIC KEY-----\n' + lines + '\n-----END PUBLIC KEY-----';
}

/** Save both keys to localStorage as exportable JWK. */
async function saveKeys() {
    if (!keyPair) { setStatus(ui.keyStatus, 'err', 'No key pair to save.'); return; }
    const pub = await crypto.subtle.exportKey('jwk', keyPair.publicKey);
    const priv = await crypto.subtle.exportKey('jwk', keyPair.privateKey);
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ pub, priv }));
    setStatus(ui.keyStatus, 'ok', 'Keys saved to localStorage.');
}

/** Load keys from localStorage. */
async function loadKeys() {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (!stored) { setStatus(ui.keyStatus, 'err', 'No saved keys found.'); return; }
    const { pub, priv } = JSON.parse(stored);
    const publicKey = await crypto.subtle.importKey('jwk', pub, 'Ed25519', true, ['verify']);
    const privateKey = await crypto.subtle.importKey('jwk', priv, 'Ed25519', true, ['sign']);
    keyPair = { publicKey, privateKey };
    publicPem = await exportPublicKeyPem(publicKey);
    ui.publicKeyPem.value = publicPem;
    setStatus(ui.keyStatus, 'ok', 'Keys loaded from localStorage.');
}

function copyPublicKey() {
    if (!publicPem) { setStatus(ui.keyStatus, 'err', 'No public key to copy.'); return; }
    navigator.clipboard.writeText(publicPem);
    setStatus(ui.keyStatus, 'ok', 'Public key PEM copied to clipboard.');
}

// ---------------------------------------------------------------------------
// 2. JWT Signing (Web Crypto)
// ---------------------------------------------------------------------------

/** Base64url encode a Uint8Array or ArrayBuffer. */
function b64url(buf) {
    const bytes = buf instanceof ArrayBuffer ? new Uint8Array(buf) : buf;
    return btoa(String.fromCharCode(...bytes))
        .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/**
 * Create and sign a JWT using the Ed25519 private key.
 * Claims: iat, exp. Add sub/aud/iss as needed.
 */
async function createJwt(lifetimeSec) {
    if (!keyPair) throw new Error('No key pair — generate or load keys first.');

    const header = { alg: 'EdDSA', typ: 'JWT' };
    const now = Math.floor(Date.now() / 1000);
    const payload = { iat: now, exp: now + lifetimeSec };

    const enc = new TextEncoder();
    const signingInput = b64url(enc.encode(JSON.stringify(header))) + '.' +
                         b64url(enc.encode(JSON.stringify(payload)));
    const sig = await crypto.subtle.sign('Ed25519', keyPair.privateKey, enc.encode(signingInput));

    return signingInput + '.' + b64url(sig);
}

// ---------------------------------------------------------------------------
// 3. Interactive Terminal (xterm.js + ttyd WebSocket)
// ---------------------------------------------------------------------------

/**
 * ttyd WebSocket protocol:
 *   Client → Server:  0 + input bytes   (stdin)
 *                      1 + JSON resize   (e.g. {"columns":80,"rows":24})
 *   Server → Client:  0 + output bytes  (stdout)
 *                      1 + JSON config   (title etc.)
 *                      2 + JSON title
 */

async function connectTerminal() {
    const host = ui.host.value.trim();
    if (!host) { setStatus(ui.connStatus, 'err', 'Enter a host.'); return; }

    const lifetime = parseInt(ui.jwtLifetime.value) || 3600;
    let token;
    try {
        token = await createJwt(lifetime);
    } catch (e) {
        setStatus(ui.connStatus, 'err', e.message);
        return;
    }

    // Clean up previous connection
    disconnectTerminal();

    // Create terminal
    terminal = new Terminal({ cursorBlink: true, fontSize: 14 });
    const fitAddon = new FitAddon.FitAddon();
    terminal.loadAddon(fitAddon);
    terminal.open(ui.termContainer);
    fitAddon.fit();

    // Resize on window resize
    const onResize = () => fitAddon.fit();
    window.addEventListener('resize', onResize);
    terminal._onResizeCleanup = () => window.removeEventListener('resize', onResize);

    // Connect WebSocket
    const wsUrl = 'wss://' + host + '/ws?token=' + encodeURIComponent(token);
    setStatus(ui.connStatus, 'info', 'Connecting to ' + host + '...');

    termSocket = new WebSocket(wsUrl);
    termSocket.binaryType = 'arraybuffer';

    termSocket.onopen = () => {
        setStatus(ui.connStatus, 'ok', 'Connected.');
        ui.btnConnect.disabled = true;
        ui.btnDisconnect.disabled = false;

        // Send initial terminal size
        const msg = '1' + JSON.stringify({ columns: terminal.cols, rows: terminal.rows });
        termSocket.send(new TextEncoder().encode(msg));
    };

    termSocket.onmessage = (ev) => {
        const data = new Uint8Array(ev.data);
        const msgType = data[0];
        const payload = data.slice(1);
        if (msgType === 0) {
            // stdout
            terminal.write(payload);
        }
        // msgType 1 = config, 2 = title — ignored for simplicity
    };

    termSocket.onclose = () => {
        setStatus(ui.connStatus, 'info', 'Disconnected.');
        ui.btnConnect.disabled = false;
        ui.btnDisconnect.disabled = true;
    };

    termSocket.onerror = () => {
        setStatus(ui.connStatus, 'err', 'WebSocket error — check host, token, and that the machine is running.');
    };

    // Send keystrokes
    terminal.onData((data) => {
        if (termSocket && termSocket.readyState === WebSocket.OPEN) {
            const bytes = new TextEncoder().encode(data);
            const msg = new Uint8Array(1 + bytes.length);
            msg[0] = 0; // stdin type
            msg.set(bytes, 1);
            termSocket.send(msg);
        }
    });

    // Send resize events
    terminal.onResize(({ cols, rows }) => {
        if (termSocket && termSocket.readyState === WebSocket.OPEN) {
            const msg = '1' + JSON.stringify({ columns: cols, rows: rows });
            termSocket.send(new TextEncoder().encode(msg));
        }
    });
}

function disconnectTerminal() {
    if (termSocket) {
        termSocket.close();
        termSocket = null;
    }
    if (terminal) {
        if (terminal._onResizeCleanup) terminal._onResizeCleanup();
        terminal.dispose();
        terminal = null;
    }
    ui.btnConnect.disabled = false;
    ui.btnDisconnect.disabled = true;
}

// ---------------------------------------------------------------------------
// 4. Programmatic Command Execution
// ---------------------------------------------------------------------------

/**
 * Execute a command on a fresh WebSocket connection and capture output.
 *
 * Strategy: send a wrapped command with unique sentinel markers, then collect
 * everything between the markers. This avoids parsing prompts or escape codes.
 *
 * Returns: { stdout: string, exitCode: number }
 */
async function execCommand(command) {
    const host = ui.host.value.trim();
    if (!host) throw new Error('Enter a host.');

    const lifetime = parseInt(ui.jwtLifetime.value) || 3600;
    const token = await createJwt(lifetime);
    const wsUrl = 'wss://' + host + '/ws?token=' + encodeURIComponent(token);

    return new Promise((resolve, reject) => {
        const ws = new WebSocket(wsUrl);
        ws.binaryType = 'arraybuffer';

        let output = '';
        let settled = false;
        const sentinel = '__EXEC_' + Math.random().toString(36).slice(2, 10) + '__';
        const startMarker = sentinel + '_START';
        const endMarker = sentinel + '_END';

        const timeout = setTimeout(() => {
            if (!settled) {
                settled = true;
                ws.close();
                reject(new Error('Command timed out after 30s'));
            }
        }, 30000);

        ws.onopen = () => {
            // Wait briefly for the shell prompt, then send the wrapped command.
            // TERM=dumb suppresses most escape sequences in command output.
            setTimeout(() => {
                const wrapped =
                    'export TERM=dumb\n' +
                    'echo ' + startMarker + '\n' +
                    command + '\n' +
                    'echo ' + endMarker + ' $?\n';
                const bytes = new TextEncoder().encode(wrapped);
                const msg = new Uint8Array(1 + bytes.length);
                msg[0] = 0;
                msg.set(bytes, 1);
                ws.send(msg);
            }, 500);
        };

        ws.onmessage = (ev) => {
            const data = new Uint8Array(ev.data);
            if (data[0] === 0) {
                output += new TextDecoder().decode(data.slice(1));

                // Check if we have both markers
                const startIdx = output.indexOf(startMarker + '\n');
                const endIdx = output.indexOf(endMarker + ' ');
                if (startIdx !== -1 && endIdx !== -1 && endIdx > startIdx) {
                    settled = true;
                    clearTimeout(timeout);

                    const body = output.slice(startIdx + startMarker.length + 1, endIdx);
                    // Extract exit code from the line containing the end marker
                    const afterEnd = output.slice(endIdx + endMarker.length + 1);
                    const exitCode = parseInt(afterEnd.trim().split(/\s/)[0]) || 0;

                    ws.close();
                    resolve({ stdout: body.trim(), exitCode });
                }
            }
        };

        ws.onerror = () => {
            if (!settled) {
                settled = true;
                clearTimeout(timeout);
                reject(new Error('WebSocket error'));
            }
        };

        ws.onclose = () => {
            if (!settled) {
                settled = true;
                clearTimeout(timeout);
                reject(new Error('Connection closed before command completed'));
            }
        };
    });
}

async function onExec() {
    const cmd = ui.execCmd.value.trim();
    if (!cmd) { setStatus(ui.execStatus, 'err', 'Enter a command.'); return; }

    setStatus(ui.execStatus, 'info', 'Running...');
    ui.execOutput.textContent = '';
    ui.btnExec.disabled = true;

    try {
        const result = await execCommand(cmd);
        ui.execOutput.textContent = result.stdout;
        setStatus(ui.execStatus, 'ok', 'Exit code: ' + result.exitCode);
    } catch (e) {
        setStatus(ui.execStatus, 'err', e.message);
    } finally {
        ui.btnExec.disabled = false;
    }
}

// ---------------------------------------------------------------------------
// Event wiring
// ---------------------------------------------------------------------------

ui.btnGenerate.addEventListener('click', generateKeyPair);
ui.btnExportPub.addEventListener('click', copyPublicKey);
ui.btnSaveKeys.addEventListener('click', saveKeys);
ui.btnLoadKeys.addEventListener('click', loadKeys);
ui.btnConnect.addEventListener('click', connectTerminal);
ui.btnDisconnect.addEventListener('click', disconnectTerminal);
ui.btnExec.addEventListener('click', onExec);

// Try loading saved keys on startup
loadKeys().catch(() => {});
