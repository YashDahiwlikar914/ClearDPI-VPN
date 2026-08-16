# ClearDPI VPN

ClearDPI VPN runs on an Ubuntu VPS and provides clients for Windows and Android.

The server has two paths.

| Path | Transport | Use |
|---|---|---|
| TCP | VLESS Reality on TCP 443 | Downloads and networks that restrict UDP |
| UDP | Hysteria2 on UDP 8443 | Gaming when UDP works |

The setup script creates the UUID, passwords, Reality keys, and certificates on the VPS. Generated client files stay outside Git.

## Requirements

You need an Ubuntu 22.04 or newer VPS with a public IPv4 address. You also need root access through SSH.

The VPS needs `curl`, `openssl`, `tar`, and `iptables`. Ubuntu images normally include these tools except `iptables` on some minimal images.

For AWS, add these security group rules.

| Protocol | Port | Source |
|---|---:|---|
| TCP | 443 | `0.0.0.0/0` |
| UDP | 8443 | `0.0.0.0/0` |
| UDP | 53, 123, 443, 3074, 3478, 19302 | Optional port disguises |
| TCP | 22 | Your management IP only |

Keep SSH limited to your own IP when possible.

## Install The Server

Run these commands from this repository. Replace `SERVER_IP` with the public IPv4 address of your VPS.

```bash
scp ClearDPI.sh ubuntu@SERVER_IP:/tmp/ClearDPI.sh
ssh ubuntu@SERVER_IP 'sudo bash /tmp/ClearDPI.sh'
```

After the repository is public, the script can run directly from GitHub. Replace `GITHUB_USER` with the GitHub account that owns the repository.

```bash
curl -fsSL https://raw.githubusercontent.com/GITHUB_USER/ClearDPI-VPN/main/ClearDPI.sh | ssh ubuntu@SERVER_IP 'sudo bash -s'
```

This downloads the script on the local machine and sends it to the VPS over SSH. The script still runs as root on the VPS.

When already connected to the VPS, use the shorter command.

```bash
curl -fsSL https://raw.githubusercontent.com/GITHUB_USER/ClearDPI-VPN/main/ClearDPI.sh | sudo bash
```

Pin the command to a release tag or commit when using it on a real server. A branch such as `main` can change later.

The script downloads the latest sing-box release for the VPS architecture. It then creates the server configuration, enables BBR, applies the TCP and UDP settings, and starts two systemd services.

Run the safe preflight check before installation.

```bash
curl -fsSL https://raw.githubusercontent.com/GITHUB_USER/ClearDPI-VPN/main/ClearDPI.sh | sudo bash -s -- --check
```

The check does not install anything or change the server.

The client files are written to `/root/ClearDPI-VPN/Clients`.

If the VPS has more than one public address, pass the address directly.

```bash
ssh ubuntu@SERVER_IP 'sudo SERVER_IP=SERVER_IP bash /tmp/ClearDPI.sh'
```

## Copy The Client Files

Copy the generated directory to your local machine through SSH.

```bash
scp -r ubuntu@SERVER_IP:/root/ClearDPI-VPN/Clients ./generated
```

The `generated` directory is ignored by Git. Do not commit it. The files contain the credentials for your server.

## Windows 11

Download the Windows x64 sing-box release. Extract `sing-box.exe` and `wintun.dll` into the same directory.

Copy `generated/windows-tcp.json` into that directory as `config.json`. Open PowerShell as Administrator and start sing-box.

```powershell
cd C:\sing-box
.\sing-box.exe run -c config.json
```

Use `windows-udp.json` when UDP is allowed. Use `windows-auto.json` when you want sing-box to test both paths during startup. The selected path stays active until the VPN stops.

The sing-box log shows the selected transport as UDP or TCP.

Windows 11 keeps its normal TCP settings in this project. Check them without changing anything.

```powershell
netsh int tcp show global
Get-NetTCPSetting -SettingName InternetCustom
```

Receive window autotuning should show `normal`.

## Android

Install sing-box for Android. Import `generated/android-tcp.json`, grant VPN permission, and start the profile.

Exclude sing-box from battery optimization. Android can stop VPN services that run in the background.

Use `android-udp.json` when UDP is allowed. Use `android-auto.json` when you want sing-box to test both paths during startup. The selected path stays active until the VPN stops.

Open the sing-box log view to see the selected transport as UDP or TCP.

## How Automatic Selection Works

The automatic profile runs the built-in sing-box URL test when the VPN starts. It checks whether each path works and compares probe latency. It does not run a large download or test a game server.

The selected path does not change during the connection. Stop and start the VPN when the network changes and you want a new decision.

Use the TCP profile for downloads. Use the UDP profile for games when the network allows UDP. These profiles remove the selection step and make the transport clear.

## Verify The Connection

Open this address after starting the VPN.

```text
https://ifconfig.me
```

It should show the public IPv4 address of the VPS.

Check the server from Ubuntu.

```bash
sudo systemctl status sing-box
sudo journalctl -u sing-box -f
sudo systemctl status college-gaming-vpn-redirect
```

## Manage The Server

```bash
sudo systemctl restart sing-box
sudo systemctl stop sing-box
sudo systemctl disable sing-box
```

The generated client files contain private credentials. Transfer them over SSH or another private channel. Do not publish them.
