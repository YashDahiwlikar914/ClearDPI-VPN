#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--check" ]; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|aarch64) ;;
    *) echo "This VPS uses an unsupported architecture. It reported $ARCH."; exit 1 ;;
  esac

  for CMD in curl openssl tar iptables systemctl; do
    command -v "$CMD" >/dev/null || { echo "$CMD is missing."; exit 1; }
  done

  SERVER_IP="${SERVER_IP:-$(curl -4fsS --max-time 5 https://api.ipify.org)}"
  curl -fsSL --max-time 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest >/dev/null
  echo "ClearDPI checks passed."
  echo "VPS architecture is $ARCH."
  echo "Server IP is $SERVER_IP."
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root."
  exit 1
fi

SERVER_IP="${SERVER_IP:-$(curl -4fsS --max-time 5 https://api.ipify.org)}"
SING_BOX_VERSION="${SING_BOX_VERSION:-}"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/sing-box"
CLIENT_DIR="/root/ClearDPI-VPN/Clients"
ARCH="$(uname -m)"

case "$ARCH" in
  x86_64) SING_BOX_ARCH="amd64" ;;
  aarch64) SING_BOX_ARCH="arm64" ;;
  *) echo "This VPS uses an unsupported architecture. It reported $ARCH."; exit 1 ;;
esac

if [ -z "$SING_BOX_VERSION" ]; then
  SING_BOX_VERSION="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | awk -F'"' '/"tag_name"/ {print $4; exit}')"
fi

if [ -z "$SING_BOX_VERSION" ]; then
  echo "Could not find the latest sing-box release. Set SING_BOX_VERSION and try again."
  exit 1
fi

command -v curl >/dev/null || { echo "Curl is missing."; exit 1; }
command -v openssl >/dev/null || { echo "OpenSSL is missing."; exit 1; }
command -v tar >/dev/null || { echo "Tar is missing."; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE="sing-box-${SING_BOX_VERSION}-linux-${SING_BOX_ARCH}.tar.gz"
URL="https://github.com/SagerNet/sing-box/releases/download/${SING_BOX_VERSION}/${ARCHIVE}"
curl -fL "$URL" -o "$TMP_DIR/$ARCHIVE"
tar -xzf "$TMP_DIR/$ARCHIVE" -C "$TMP_DIR"
install -m 0755 "$(find "$TMP_DIR" -type f -name sing-box -print -quit)" "$INSTALL_DIR/sing-box"

install -d -m 0700 "$CONFIG_DIR" "$CLIENT_DIR"

UUID="$(cat /proc/sys/kernel/random/uuid)"
HY2_PASSWORD="$(openssl rand -hex 24)"
OBFS_PASSWORD="$(openssl rand -hex 24)"
REALITY_KEYS="$($INSTALL_DIR/sing-box generate reality-keypair)"
REALITY_PRIVATE_KEY="$(printf '%s\n' "$REALITY_KEYS" | awk '/PrivateKey:/ {print $2}')"
REALITY_PUBLIC_KEY="$(printf '%s\n' "$REALITY_KEYS" | awk '/PublicKey:/ {print $2}')"

if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
  echo "Could not generate the Reality keys."
  exit 1
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj "/CN=www.cloudflare.com" \
  -keyout "$CONFIG_DIR/server.key" \
  -out "$CONFIG_DIR/server.crt" >/dev/null 2>&1
chmod 0600 "$CONFIG_DIR/server.key"

cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": {"level": "warn", "timestamp": true},
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": 443,
      "tcp_fast_open": true,
      "tcp_keep_alive": "30s",
      "tcp_keep_alive_interval": "15s",
      "users": [{"name": "client", "uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "www.cloudflare.com",
        "reality": {
          "enabled": true,
          "handshake": {"server": "www.cloudflare.com", "server_port": 443},
          "private_key": "$REALITY_PRIVATE_KEY",
          "short_id": ["$(openssl rand -hex 4)"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 8443,
      "users": [{"name": "client", "password": "$HY2_PASSWORD"}],
      "obfs": {"type": "salamander", "password": "$OBFS_PASSWORD"},
      "tls": {
        "enabled": true,
        "server_name": "www.cloudflare.com",
        "certificate_path": "$CONFIG_DIR/server.crt",
        "key_path": "$CONFIG_DIR/server.key"
      },
      "masquerade": "https://www.cloudflare.com/"
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF

cat > /etc/sysctl.d/99-college-gaming-vpn.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_notsent_lowat = 16384
EOF
sysctl --system >/dev/null

cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=ClearDPI VPN Server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/sbin/college-gaming-vpn-redirect <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-start}"
for PORT in 53 123 443 3074 3478 19302; do
  if [ "$ACTION" = "start" ]; then
    iptables -t nat -C PREROUTING -p udp --dport "$PORT" -j REDIRECT --to-port 8443 2>/dev/null || \
      iptables -t nat -A PREROUTING -p udp --dport "$PORT" -j REDIRECT --to-port 8443
  else
    iptables -t nat -C PREROUTING -p udp --dport "$PORT" -j REDIRECT --to-port 8443 2>/dev/null && \
      iptables -t nat -D PREROUTING -p udp --dport "$PORT" -j REDIRECT --to-port 8443 || true
  fi
done
EOF
chmod 0755 /usr/local/sbin/college-gaming-vpn-redirect

cat > /etc/systemd/system/college-gaming-vpn-redirect.service <<'EOF'
[Unit]
Description=ClearDPI VPN UDP Port Disguises
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/local/sbin/college-gaming-vpn-redirect start
ExecStop=/usr/local/sbin/college-gaming-vpn-redirect stop

[Install]
WantedBy=multi-user.target
EOF

"$INSTALL_DIR/sing-box" check -c "$CONFIG_DIR/config.json"
systemctl daemon-reload
systemctl enable --now sing-box
systemctl enable --now college-gaming-vpn-redirect

SHORT_ID="$(awk -F'"' '/"short_id"/ {print $4; exit}' "$CONFIG_DIR/config.json")"

write_client() {
  local platform="$1" stack="$2" interface="$3"
  local tcp_file="$CLIENT_DIR/${platform}-tcp.json"
  local udp_file="$CLIENT_DIR/${platform}-udp.json"
  local auto_file="$CLIENT_DIR/${platform}-auto.json"
  local tun_interface=""
  [ -n "$interface" ] && tun_interface="\"interface_name\": \"$interface\"," 

  cat > "$tcp_file" <<EOF
{
  "log": {"level": "info"},
  "dns": {"servers": [{"type": "udp", "tag": "dns", "server": "1.1.1.1", "detour": "vless-out"}], "final": "dns", "strategy": "ipv4_only"},
  "inbounds": [{"type": "tun", "tag": "tun-in", $tun_interface "address": ["172.19.0.1/30"], "mtu": 1400, "auto_route": true, "strict_route": true, "stack": "$stack"}],
  "outbounds": [
    {"type": "vless", "tag": "vless-out", "server": "$SERVER_IP", "server_port": 443, "uuid": "$UUID", "flow": "xtls-rprx-vision", "tcp_fast_open": true, "tcp_keep_alive": "30s", "tcp_keep_alive_interval": "15s", "tls": {"enabled": true, "server_name": "www.cloudflare.com", "utls": {"enabled": true, "fingerprint": "chrome"}, "reality": {"enabled": true, "public_key": "$REALITY_PUBLIC_KEY", "short_id": "$SHORT_ID"}}},
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"rules": [{"action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"}, {"ip_cidr": ["$SERVER_IP/32"], "outbound": "direct"}], "final": "vless-out", "auto_detect_interface": true}
}
EOF

  cat > "$udp_file" <<EOF
{
  "log": {"level": "warn"},
  "dns": {"servers": [{"type": "udp", "tag": "dns", "server": "1.1.1.1", "detour": "hy2-out"}], "final": "dns", "strategy": "ipv4_only"},
  "inbounds": [{"type": "tun", "tag": "tun-in", $tun_interface "address": ["172.19.0.1/30"], "mtu": 1400, "auto_route": true, "strict_route": true, "stack": "$stack"}],
  "outbounds": [
    {"type": "hysteria2", "tag": "hy2-out", "server": "$SERVER_IP", "server_port": 53, "password": "$HY2_PASSWORD", "obfs": {"type": "salamander", "password": "$OBFS_PASSWORD"}, "tls": {"enabled": true, "insecure": true, "server_name": "www.cloudflare.com"}},
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"rules": [{"action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"}, {"ip_cidr": ["$SERVER_IP/32"], "outbound": "direct"}], "final": "hy2-out", "auto_detect_interface": true}
}
EOF

  cat > "$auto_file" <<EOF
{
  "log": {"level": "info"},
  "dns": {"servers": [{"type": "udp", "tag": "dns", "server": "1.1.1.1", "detour": "vless-out"}], "final": "dns", "strategy": "ipv4_only"},
  "inbounds": [{"type": "tun", "tag": "tun-in", $tun_interface "address": ["172.19.0.1/30"], "mtu": 1400, "auto_route": true, "strict_route": true, "stack": "$stack"}],
  "outbounds": [
    {"type": "urltest", "tag": "auto", "outbounds": ["hy2-out", "vless-out"], "url": "https://www.gstatic.com/generate_204", "interval": "876000h", "tolerance": 100, "interrupt_exist_connections": false},
    {"type": "hysteria2", "tag": "hy2-out", "server": "$SERVER_IP", "server_port": 53, "password": "$HY2_PASSWORD", "obfs": {"type": "salamander", "password": "$OBFS_PASSWORD"}, "tls": {"enabled": true, "insecure": true, "server_name": "www.cloudflare.com"}},
    {"type": "vless", "tag": "vless-out", "server": "$SERVER_IP", "server_port": 443, "uuid": "$UUID", "flow": "xtls-rprx-vision", "tcp_fast_open": true, "tcp_keep_alive": "30s", "tcp_keep_alive_interval": "15s", "tls": {"enabled": true, "server_name": "www.cloudflare.com", "utls": {"enabled": true, "fingerprint": "chrome"}, "reality": {"enabled": true, "public_key": "$REALITY_PUBLIC_KEY", "short_id": "$SHORT_ID"}}},
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"rules": [{"action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"}, {"ip_cidr": ["$SERVER_IP/32"], "outbound": "direct"}], "final": "auto", "auto_detect_interface": true}
}
EOF
  chmod 0600 "$tcp_file" "$udp_file" "$auto_file"
}

write_client windows gvisor sing-box
write_client android system ""
cat > "$CLIENT_DIR/README.txt" <<EOF
Server IP is $SERVER_IP
Reality public key is $REALITY_PUBLIC_KEY
Reality short ID is $SHORT_ID

Import the profile for your device. Keep this directory private.
EOF
chmod 0600 "$CLIENT_DIR/README.txt"

echo "The setup is complete."
echo "Check the server with systemctl status sing-box."
echo "Your client profiles are in $CLIENT_DIR."
