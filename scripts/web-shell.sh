#!/usr/bin/env bash
if [[ -n "$MACHINE_SCRIPT_DEBUG" ]]; then
    set -x
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

APT_INSTALL="sudo --preserve-env=DEBIAN_FRONTEND,NEEDRESTART_MODE apt -y install"

set -eo pipefail  ## https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/

echo "***********************************************************************"
echo "* web-shell.sh"
echo "***********************************************************************"
echo "$0 called with $*"

# Defaults
TTYD_PORT=7681
VERIFY_PORT=9222
SHELL_USER="webshell"
FQDN=""
JWT_PUBLIC_KEY_FILE=""
FORCE=false

while (( "$#" )); do
   case $1 in
      --fqdn)
         shift&&FQDN="$1"||{ echo "Missing --fqdn value"; exit 1; }
         ;;
      --jwt-public-key-file)
         shift&&JWT_PUBLIC_KEY_FILE="$1"||{ echo "Missing --jwt-public-key-file value"; exit 1; }
         ;;
      --shell-user)
         shift&&SHELL_USER="$1"||{ echo "Missing --shell-user value"; exit 1; }
         ;;
      -f)
         FORCE=true
         ;;
      *)
         echo "Unrecognized argument: $1"
         ;;
   esac
   shift
done

# Validate required arguments
if [[ -z "$FQDN" ]]; then
    echo "Error: --fqdn is required (for Let's Encrypt TLS)"
    exit 1
fi
if [[ -z "$JWT_PUBLIC_KEY_FILE" ]]; then
    echo "Error: --jwt-public-key-file is required (PEM-encoded public key for JWT verification)"
    exit 1
fi
if [[ ! -f "$JWT_PUBLIC_KEY_FILE" ]]; then
    echo "Error: JWT public key file not found: $JWT_PUBLIC_KEY_FILE"
    exit 1
fi

# Check if already installed
if [[ "$FORCE" != "true" ]]; then
    which ttyd >/dev/null 2>&1 && rc=$? || rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "ttyd already installed. Use -f to force reinstall."
        exit 0
    fi
fi

echo "***********************************************************************"
echo "* Installing packages"
echo "***********************************************************************"

sudo apt update
$APT_INSTALL ca-certificates curl python3-jwt python3-cryptography

# Install Caddy from official repository
if ! which caddy >/dev/null 2>&1; then
    echo "***********************************************************************"
    echo "* Installing Caddy"
    echo "***********************************************************************"
    $APT_INSTALL debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt update
    $APT_INSTALL caddy
fi

# Install ttyd binary
echo "***********************************************************************"
echo "* Installing ttyd"
echo "***********************************************************************"
TTYD_VERSION="1.7.7"
ARCH=$(uname -m)
case $ARCH in
    x86_64)  TTYD_ARCH="x86_64" ;;
    aarch64) TTYD_ARCH="aarch64" ;;
    armv7l)  TTYD_ARCH="armhf" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
curl -fsSL -o /tmp/ttyd.$$ "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}"
sudo install -m 755 /tmp/ttyd.$$ /usr/local/bin/ttyd
rm -f /tmp/ttyd.$$

# Create shell user if needed
if ! id "$SHELL_USER" >/dev/null 2>&1; then
    echo "***********************************************************************"
    echo "* Creating user: $SHELL_USER"
    echo "***********************************************************************"
    sudo useradd -m -s /bin/bash "$SHELL_USER"
fi

# Set up config directory
echo "***********************************************************************"
echo "* Writing configuration"
echo "***********************************************************************"
sudo mkdir -p /etc/web-shell
sudo cp "$JWT_PUBLIC_KEY_FILE" /etc/web-shell/public.pem
sudo chmod 644 /etc/web-shell/public.pem

# Write JWT verification service
sudo tee /etc/web-shell/jwt-verify.py > /dev/null << 'PYEOF'
#!/usr/bin/env python3
"""Tiny JWT verification service for Caddy forward_auth."""
import sys, http.server
from urllib.parse import urlparse, parse_qs
import jwt

PUBLIC_KEY_PATH = sys.argv[1]
LISTEN_PORT = int(sys.argv[2])

with open(PUBLIC_KEY_PATH, 'rb') as f:
    PUBLIC_KEY = f.read()

ALGORITHMS = ["EdDSA", "RS256", "RS384", "RS512", "ES256", "ES384", "ES512"]

class AuthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        uri = self.headers.get('X-Forwarded-Uri', self.path)
        params = parse_qs(urlparse(uri).query)
        token = params.get('token', [None])[0]
        if token:
            try:
                jwt.decode(token, PUBLIC_KEY, algorithms=ALGORITHMS)
                self.send_response(200)
                self.end_headers()
                return
            except jwt.exceptions.PyJWTError:
                pass
        self.send_response(401)
        self.end_headers()

    def log_message(self, format, *args):
        pass

http.server.HTTPServer(('127.0.0.1', LISTEN_PORT), AuthHandler).serve_forever()
PYEOF
sudo chmod 644 /etc/web-shell/jwt-verify.py

# Write Caddyfile
sudo tee /etc/caddy/Caddyfile > /dev/null << CADDYEOF
${FQDN} {
    @ws path /ws
    forward_auth @ws 127.0.0.1:${VERIFY_PORT} {
        uri /verify
    }
    reverse_proxy 127.0.0.1:${TTYD_PORT}
}
CADDYEOF

# Write systemd unit for ttyd
sudo tee /etc/systemd/system/ttyd.service > /dev/null << SVCEOF
[Unit]
Description=ttyd web terminal
After=network.target

[Service]
Type=simple
User=${SHELL_USER}
ExecStart=/usr/local/bin/ttyd --port ${TTYD_PORT} --interface lo --ping-interval 30 bash -l
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

# Write systemd unit for JWT verifier
sudo tee /etc/systemd/system/jwt-verify.service > /dev/null << SVCEOF
[Unit]
Description=JWT verification service for web-shell
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/bin/python3 /etc/web-shell/jwt-verify.py /etc/web-shell/public.pem ${VERIFY_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

# Enable and start services
echo "***********************************************************************"
echo "* Starting services"
echo "***********************************************************************"
sudo systemctl daemon-reload
sudo systemctl enable --now jwt-verify.service
sudo systemctl enable --now ttyd.service
sudo systemctl restart caddy

echo "***********************************************************************"
echo "* web-shell.sh complete"
echo "***********************************************************************"
echo "  FQDN:       ${FQDN}"
echo "  Shell user:  ${SHELL_USER}"
echo "  ttyd:        127.0.0.1:${TTYD_PORT} (localhost only)"
echo "  JWT verify:  127.0.0.1:${VERIFY_PORT} (localhost only)"
echo "  Caddy:       https://${FQDN} (Let's Encrypt TLS)"
echo ""
echo "  Interactive: https://${FQDN}/?token=<JWT>"
echo "  WebSocket:   wss://${FQDN}/ws?token=<JWT>"
