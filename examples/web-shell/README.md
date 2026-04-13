# Web Shell — Browser-Based Remote Shell Access

Web Shell provides secure, browser-based terminal access to a provisioned machine. It supports both interactive shell sessions and programmatic command execution from JavaScript, authenticated using asymmetric cryptography (no shared secrets).

## Architecture

```
┌─────────────────────────────────────────┐
│  Browser                                │
│                                         │
│  Web Crypto API  ──►  JWT (signed)      │
│  xterm.js        ◄──► WebSocket         │
│  JS/TS app code  ──►  command exec      │
└──────────────┬──────────────────────────┘
               │  wss://host/ws?token=<JWT>
               ▼
┌──────────────────────────────────────────┐
│  Machine                                 │
│                                          │
│  Caddy (Let's Encrypt TLS)               │
│    │  forward_auth on /ws                │
│    ▼                                     │
│  jwt-verify.py (validates JWT signature) │
│    │  200 OK → proxy                     │
│    ▼                                     │
│  ttyd (terminal server, localhost only)  │
│    │  runs bash as shell user            │
│    ▼                                     │
│  bash -l                                 │
└──────────────────────────────────────────┘
```

### Components on the machine

| Component | Role | Listens on |
|-----------|------|------------|
| **Caddy** | TLS termination (Let's Encrypt), reverse proxy, auth gating | Port 443 (public) |
| **jwt-verify.py** | Validates JWT signature against the provisioned public key | localhost:9222 |
| **ttyd** | Terminal server — connects browser WebSocket to a bash session | localhost:7681 |

Only Caddy is exposed to the network. ttyd and the JWT verifier listen on localhost only.

### Authentication flow

1. During provisioning, an Ed25519 (or RSA/ECDSA) **public key** is placed on the machine. The corresponding private key never leaves the client.
2. The browser signs a JWT using the private key (via the Web Crypto API).
3. The JWT is sent as a query parameter: `wss://host/ws?token=<JWT>`.
4. Caddy's `forward_auth` passes the request to `jwt-verify.py`, which verifies the signature and checks token expiry.
5. If valid, Caddy proxies the WebSocket connection to ttyd.

This means **no shared secret** (password, API key, etc.) passes through the cloud-init chain of custody — only the public key is provisioned onto the machine.

### Why a query parameter for the token?

The browser WebSocket API does not support setting custom HTTP headers. The token must be passed as a query parameter or a cookie. A query parameter is simplest and avoids session/cookie management.

## Setup

### Prerequisites

- A machine with a public IP and a DNS record pointing to it (required for Let's Encrypt).
- The provisioning scripts from this repository.

### Step 1: Generate a key pair

Open the example app (`examples/web-shell/index.html`) in a browser and click **Generate Key Pair**. This creates an Ed25519 key pair entirely in the browser using the Web Crypto API.

Copy the **Public Key (PEM)** from the text area and save it to a file (e.g. `public.pem`). Click **Save Keys to localStorage** to persist the private key in the browser for later use.

Alternatively, generate keys with OpenSSL on any machine you control:

```bash
openssl genpkey -algorithm ed25519 -out private.pem
openssl pkey -in private.pem -pubonly -out public.pem
```

(If using OpenSSL, you would need to import the private key into your browser application for JWT signing.)

### Step 2: Provision the machine

The public key file must be accessible on the machine during provisioning. Place it via cloud-init `write_files`, a shared volume, or any other mechanism.

Run `web-shell.sh` directly:

```bash
web-shell.sh --fqdn shell.example.com --jwt-public-key-file /path/to/public.pem
```

Or via `combine.sh` alongside other provisioning scripts:

```bash
combine.sh \
  --script-url packages.sh --script-args "build-essential" \
  --script-url web-shell.sh \
  --script-args "--fqdn shell.example.com --jwt-public-key-file /path/to/public.pem --shell-user myuser"
```

Example `~/.machine/config.yaml`:

```yaml
machines:
    dev-box:
        new-user-name: dev
        script-url: https://raw.githubusercontent.com/stirlingbridge/machine-provisioning/refs/heads/main/scripts/combine.sh
        script-args: >-
          --script-url web-shell.sh
          --script-args "--fqdn shell.example.com --jwt-public-key-file /opt/keys/public.pem --shell-user dev"
```

### Step 3: Connect

Open the example app in a browser, enter the machine's FQDN, and click **Connect Terminal**. If you saved keys to localStorage in Step 1, they will be loaded automatically.

### Script arguments

| Argument | Required | Default | Description |
|----------|----------|---------|-------------|
| `--fqdn DOMAIN` | Yes | — | Domain name for the machine. Caddy uses this for the Let's Encrypt certificate. |
| `--jwt-public-key-file PATH` | Yes | — | Path to a PEM-encoded public key file (Ed25519, RSA, or ECDSA) on the machine. |
| `--shell-user NAME` | No | `webshell` | Linux user that shell sessions run as. Created if it doesn't exist. |
| `-f` | No | — | Force reinstall even if ttyd is already present. |

## Usage

### Interactive terminal

The example app's **Interactive Terminal** section provides a full terminal experience using xterm.js. It connects via WebSocket to ttyd, which runs `bash -l` as the configured shell user. You can type commands, use tab completion, run interactive programs (vim, top, etc.), and see output in real time — the same experience as SSH in a terminal emulator.

### Programmatic command execution

The **Programmatic Command Execution** section demonstrates running commands from JavaScript and capturing their output. This is the pattern to use when browser application code needs to orchestrate work on the remote machine.

The approach:

1. Open a fresh WebSocket connection (separate from the interactive terminal).
2. Wrap the command with unique sentinel markers:
   ```
   export TERM=dumb
   echo __START_abc123__
   your-command-here
   echo __END_abc123__ $?
   ```
3. Collect WebSocket output until both markers appear.
4. Extract the text between the markers (clean stdout) and the exit code.

`TERM=dumb` suppresses most terminal escape sequences so the captured output is clean text.

#### Using `execCommand()` in your own code

The `execCommand()` function in `web-shell.js` implements this pattern and can be adapted for any application:

```javascript
const result = await execCommand('ls -la /tmp');
console.log(result.stdout);    // clean text output
console.log(result.exitCode);  // 0
```

It returns a `{ stdout: string, exitCode: number }` object. Commands time out after 30 seconds by default.

#### Key functions in web-shell.js

| Function | Purpose |
|----------|---------|
| `generateKeyPair()` | Generate Ed25519 key pair (Web Crypto API) |
| `exportPublicKeyPem(key)` | Export public CryptoKey to PEM string |
| `createJwt(lifetimeSec)` | Sign a JWT with the private key |
| `connectTerminal()` | Open interactive terminal session |
| `execCommand(command)` | Run a command and capture output |

### ttyd WebSocket protocol

ttyd uses a simple binary WebSocket protocol with a one-byte message type prefix:

| Direction | Type byte | Payload | Meaning |
|-----------|-----------|---------|---------|
| Client → Server | `0` | UTF-8 text | stdin (keystrokes or commands) |
| Client → Server | `1` | JSON | Terminal resize: `{"columns":80,"rows":24}` |
| Server → Client | `0` | UTF-8 text | stdout (terminal output) |
| Server → Client | `1` | JSON | Configuration |
| Server → Client | `2` | JSON | Window title |

## Security considerations

- **No shared secrets on the machine.** Only the public key is provisioned. The private key exists only in the browser (or wherever the client application runs).
- **ttyd and jwt-verify only listen on localhost.** They are not reachable from the network — all access goes through Caddy.
- **JWT expiry.** Tokens include an `exp` claim. The verifier rejects expired tokens. Use short lifetimes appropriate to your use case.
- **TLS everywhere.** Caddy automatically obtains and renews a Let's Encrypt certificate. WebSocket connections use `wss://`.
- **Shell user isolation.** Sessions run as a dedicated non-root user. Configure this user's permissions, PATH, and environment to limit what can be done through the shell.
- **Single session model.** By default, ttyd shares one shell session across all connections. If you need isolated per-connection sessions, consider running ttyd with different configuration or multiple instances.

## Browser requirements

Ed25519 support in the Web Crypto API requires:

- Chrome 113+
- Firefox 130+
- Safari 17+

If your browser doesn't support Ed25519, the example app will show an error when generating keys. As a fallback, you could generate RSA or ECDSA keys instead — the JWT verifier on the machine accepts RS256, RS384, RS512, ES256, ES384, and ES512 in addition to EdDSA.

## Installed services

After provisioning, three systemd services run on the machine:

```bash
# Check status
sudo systemctl status caddy
sudo systemctl status ttyd
sudo systemctl status jwt-verify

# View logs
sudo journalctl -u ttyd -f
sudo journalctl -u jwt-verify -f
sudo journalctl -u caddy -f

# Restart after config changes
sudo systemctl restart caddy
sudo systemctl restart ttyd
sudo systemctl restart jwt-verify
```

Configuration files:

| File | Purpose |
|------|---------|
| `/etc/caddy/Caddyfile` | Caddy reverse proxy and TLS configuration |
| `/etc/web-shell/jwt-verify.py` | JWT verification service |
| `/etc/web-shell/public.pem` | Provisioned public key |
| `/etc/systemd/system/ttyd.service` | ttyd systemd unit |
| `/etc/systemd/system/jwt-verify.service` | JWT verifier systemd unit |

## Troubleshooting

**Caddy won't start / no TLS certificate**: Ensure the FQDN resolves to the machine's public IP and that port 443 (and port 80 for the ACME HTTP challenge) are open.

**WebSocket connection refused (401)**: The JWT is invalid or expired. Generate a new one. Check that the public key on the machine matches the private key used to sign the JWT.

**WebSocket connection refused (502)**: ttyd or jwt-verify isn't running. Check `systemctl status ttyd` and `systemctl status jwt-verify`.

**Terminal connects but no prompt appears**: Check that the shell user exists and has a valid shell: `getent passwd webshell`.

**Ed25519 not supported in browser**: Use a recent browser version (see Browser Requirements above) or switch to RSA/ECDSA keys.
