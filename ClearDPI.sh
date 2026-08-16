#!/usr/bin/env bash
set -Eeuo pipefail

readonly INSTALL_DIR="/usr/local/bin"
readonly CONFIG_DIR="/etc/sing-box"
readonly CLIENT_DIR="/root/ClearDPI-VPN/Clients"
readonly AUTO_TEST_INTERVAL="876000h"

valid_ipv4() {
  local address="$1"
  local octet
  local octets

  [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$address"

  for octet in "${octets[@]}"; do
    ((10#$octet <= 255)) || return 1
  done
}

require_commands() {
  local command_name

  for command_name in "$@"; do
    command -v "$command_name" >/dev/null || {
      echo "${command_name^} is missing."
      return 1
    }
  done
}

check_vps() {
  local architecture
  local server_ip

  architecture="$(uname -m)"
  case "$architecture" in
    x86_64|aarch64) ;;
    *)
      echo "This VPS uses an unsupported architecture. It reported $architecture."
      return 1
      ;;
  esac

  require_commands curl openssl tar iptables systemctl
  server_ip="${SERVER_IP:-$(curl -4fsS --max-time 5 https://api.ipify.org)}"
  valid_ipv4 "$server_ip" || {
    echo "Server IP is not a valid IPv4 address."
    return 1
  }

  curl -fsSL --max-time 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest >/dev/null
  echo "ClearDPI checks passed."
  echo "VPS architecture is $architecture."
  echo "Server IP is $server_ip."
}

install_dependencies() {
  local missing_packages=()
  local package_name

  for package_name in curl openssl tar iptables; do
    command -v "$package_name" >/dev/null || missing_packages+=("$package_name")
  done

  if [ "${#missing_packages[@]}" -eq 0 ]; then
    return
  fi

  echo "Installing missing packages ${missing_packages[*]}."
  command -v apt-get >/dev/null || {
    echo "Apt is missing. Install the required packages manually."
    return 1
  }
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
}

detect_server_ip() {
  SERVER_IP="${SERVER_IP:-$(curl -4fsS --max-time 5 https://api.ipify.org)}"
  valid_ipv4 "$SERVER_IP" || {
    echo "Server IP is not a valid IPv4 address."
    return 1
  }
  export SERVER_IP
}

detect_architecture() {
  case "$(uname -m)" in
    x86_64) SING_BOX_ARCH="amd64" ;;
    aarch64) SING_BOX_ARCH="arm64" ;;
    *)
      echo "This VPS uses an unsupported architecture. It reported $(uname -m)."
      return 1
      ;;
  esac
  export SING_BOX_ARCH
}

find_release() {
  SING_BOX_VERSION="${SING_BOX_VERSION:-}"
  if [ -z "$SING_BOX_VERSION" ]; then
    SING_BOX_VERSION="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | awk -F'"' '/"tag_name"/ {print $4; exit}')"
  fi

  if [ -z "$SING_BOX_VERSION" ]; then
    echo "Could not find the latest sing-box release. Set SING_BOX_VERSION and try again."
    return 1
  fi

  if [[ ! "$SING_BOX_VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "SING_BOX_VERSION contains invalid characters."
    return 1
  fi
  export SING_BOX_VERSION
}

install_sing_box() {
  local archive
  local archive_path
  local binary_path
  local download_url

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$TMP_DIR"' EXIT INT TERM

  archive="sing-box-${SING_BOX_VERSION}-linux-${SING_BOX_ARCH}.tar.gz"
  archive_path="$TMP_DIR/$archive"
  download_url="https://github.com/SagerNet/sing-box/releases/download/${SING_BOX_VERSION}/${archive}"

  curl -fL "$download_url" -o "$archive_path"
  tar -xzf "$archive_path" -C "$TMP_DIR"
  binary_path="$(find "$TMP_DIR" -type f -name sing-box -print -quit)"

  if [ -z "$binary_path" ]; then
    echo "The sing-box archive did not contain a binary."
    return 1
  fi

  install -m 0755 "$binary_path" "$INSTALL_DIR/sing-box"
}

generate_credentials() {
  local reality_keys

  UUID="$(cat /proc/sys/kernel/random/uuid)"
  HYSTERIA2_PASSWORD="$(openssl rand -hex 24)"
  OBFS_PASSWORD="$(openssl rand -hex 24)"
  reality_keys="$($INSTALL_DIR/sing-box generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$reality_keys" | awk '/PrivateKey:/ {print $2}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$reality_keys" | awk '/PublicKey:/ {print $2}')"

  if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
    echo "Could not generate the Reality keys."
    return 1
  fi
}

write_server_config() {
  install -d -m 0700 "$CONFIG_DIR" "$CLIENT_DIR"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=www.cloudflare.com" \
    -keyout "$CONFIG_DIR/server.key" \
    -out "$CONFIG_DIR/server.crt" >/dev/null 2>&1 || {
    echo "Could not generate the TLS certificate."
    return 1
  }
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
      "tag": "hysteria2-in",
      "listen": "::",
      "listen_port": 8443,
      "users": [{"name": "client", "password": "$HYSTERIA2_PASSWORD"}],
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
}

write_sysctl_config() {
  cat > /etc/sysctl.d/99-cleardpi-vpn.conf <<'EOF'
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
}

write_services() {
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

  cat > /usr/local/sbin/cleardpi-udp-redirect <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-start}"
for PORT in 53 123 443 3074 3478 19302; do
  if [ "$ACTION" = "start" ]; then
    iptables -t nat -C PREROUTING -p udp --dport "$PORT" -j REDIRECT --to-port 8443 2>/dev/null || \
      iptables -t nat -A PREROUTING -p udp --dport "$PORT" -j REDIRECT --to-port 8443
  elif iptables -t nat -C PREROUTING -p udp --dport "$PORT" -j REDIRECT --to-port 8443 2>/dev/null; then
    iptables -t nat -D PREROUTING -p udp --dport "$PORT" -j REDIRECT --to-port 8443
  fi
done
EOF
  chmod 0755 /usr/local/sbin/cleardpi-udp-redirect

  cat > /etc/systemd/system/cleardpi-udp-redirect.service <<'EOF'
[Unit]
Description=ClearDPI VPN UDP Port Disguises
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/local/sbin/cleardpi-udp-redirect start
ExecStop=/usr/local/sbin/cleardpi-udp-redirect stop

[Install]
WantedBy=multi-user.target
EOF
}

write_client_profile() {
  local platform="$1"
  local stack="$2"
  local interface_name="$3"
  local platform_name="${platform^}"
  local tun_interface=""
  local tcp_file="$CLIENT_DIR/${platform_name}-TCP.json"
  local udp_file="$CLIENT_DIR/${platform_name}-UDP.json"
  local auto_file="$CLIENT_DIR/${platform_name}-Auto.json"

  if [ -n "$interface_name" ]; then
    printf -v tun_interface '"interface_name": "%s",' "$interface_name"
  fi

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
  "dns": {"servers": [{"type": "udp", "tag": "dns", "server": "1.1.1.1", "detour": "hysteria2-out"}], "final": "dns", "strategy": "ipv4_only"},
  "inbounds": [{"type": "tun", "tag": "tun-in", $tun_interface "address": ["172.19.0.1/30"], "mtu": 1400, "auto_route": true, "strict_route": true, "stack": "$stack"}],
  "outbounds": [
    {"type": "hysteria2", "tag": "hysteria2-out", "server": "$SERVER_IP", "server_port": 53, "password": "$HYSTERIA2_PASSWORD", "obfs": {"type": "salamander", "password": "$OBFS_PASSWORD"}, "tls": {"enabled": true, "insecure": true, "server_name": "www.cloudflare.com"}},
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"rules": [{"action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"}, {"ip_cidr": ["$SERVER_IP/32"], "outbound": "direct"}], "final": "hysteria2-out", "auto_detect_interface": true}
}
EOF

  cat > "$auto_file" <<EOF
{
  "log": {"level": "info"},
  "dns": {"servers": [{"type": "udp", "tag": "dns", "server": "1.1.1.1", "detour": "vless-out"}], "final": "dns", "strategy": "ipv4_only"},
  "inbounds": [{"type": "tun", "tag": "tun-in", $tun_interface "address": ["172.19.0.1/30"], "mtu": 1400, "auto_route": true, "strict_route": true, "stack": "$stack"}],
  "outbounds": [
    {"type": "urltest", "tag": "auto", "outbounds": ["hysteria2-out", "vless-out"], "url": "https://www.gstatic.com/generate_204", "interval": "$AUTO_TEST_INTERVAL", "tolerance": 100, "interrupt_exist_connections": false},
    {"type": "hysteria2", "tag": "hysteria2-out", "server": "$SERVER_IP", "server_port": 53, "password": "$HYSTERIA2_PASSWORD", "obfs": {"type": "salamander", "password": "$OBFS_PASSWORD"}, "tls": {"enabled": true, "insecure": true, "server_name": "www.cloudflare.com"}},
    {"type": "vless", "tag": "vless-out", "server": "$SERVER_IP", "server_port": 443, "uuid": "$UUID", "flow": "xtls-rprx-vision", "tcp_fast_open": true, "tcp_keep_alive": "30s", "tcp_keep_alive_interval": "15s", "tls": {"enabled": true, "server_name": "www.cloudflare.com", "utls": {"enabled": true, "fingerprint": "chrome"}, "reality": {"enabled": true, "public_key": "$REALITY_PUBLIC_KEY", "short_id": "$SHORT_ID"}}},
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"rules": [{"action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"}, {"ip_cidr": ["$SERVER_IP/32"], "outbound": "direct"}], "final": "auto", "auto_detect_interface": true}
}
EOF
  chmod 0600 "$tcp_file" "$udp_file" "$auto_file"
}

write_client_profiles() {
  SHORT_ID="$(awk -F'"' '/"short_id"/ {print $4; exit}' "$CONFIG_DIR/config.json")"
  write_client_profile windows gvisor sing-box
  write_client_profile android system ""

  cat > "$CLIENT_DIR/README.txt" <<EOF
Server IP is $SERVER_IP
Reality public key is $REALITY_PUBLIC_KEY
Reality short ID is $SHORT_ID

Import the profile for your device. Keep this directory private.
EOF
  chmod 0600 "$CLIENT_DIR/README.txt"
}

install_server() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run this as root."
    return 1
  fi

  install_dependencies
  detect_server_ip
  detect_architecture
  find_release
  install_sing_box
  generate_credentials
  write_server_config
  write_sysctl_config
  write_services

  "$INSTALL_DIR/sing-box" check -c "$CONFIG_DIR/config.json"
  systemctl daemon-reload
  systemctl enable --now sing-box
  systemctl enable --now cleardpi-udp-redirect
  write_client_profiles

  echo "The setup is complete."
  echo "Check the server with systemctl status sing-box."
  echo "Your client profiles are in $CLIENT_DIR."
}

case "${1:-}" in
  "") install_server ;;
  --check) check_vps ;;
  *) echo "Usage is ClearDPI.sh or ClearDPI.sh --check."; exit 1 ;;
esac
