[English](/README.md) | [Русский](/README_RU.md) · [Telegram](https://t.me/+96HVPF3Ww6o3YTNi)

# xray-remnasub-ros

> A multi-architecture container for **MikroTik RouterOS** that runs a JSON subscription with [Xray-core](https://github.com/XTLS/Xray-core). The subscription is an array of complete Xray JSON configurations; the container selects one, adds only the fragments RouterOS interception needs, validates the result, and runs it. Subscription and container management is provided by an embedded BusyBox `httpd` + shell CGI WebUI.

[![Docker Pulls](https://img.shields.io/docker/pulls/medium1992/xray-remnasub-ros?logo=docker&label=docker%20pulls)](https://hub.docker.com/r/medium1992/xray-remnasub-ros)
[![Docker Image Size](https://img.shields.io/docker/image-size/medium1992/xray-remnasub-ros/latest?logo=docker&label=image%20size)](https://hub.docker.com/r/medium1992/xray-remnasub-ros)
[![License](https://img.shields.io/github/license/Medium1992/xray-remnasub-ros)](./LICENSE)
![Platforms](https://img.shields.io/badge/arch-amd64%20%7C%20arm64%20%7C%20armv7%20%7C%20armv5-blue)
[![Telegram](https://img.shields.io/badge/Telegram-group-blue?logo=telegram)](https://t.me/+96HVPF3Ww6o3YTNi)

## ✨ Features

- 📚 Multiple subscription profiles with an active selection, manual and scheduled refresh, and per-profile settings.
- 🧾 The provider response is stored unchanged, so the exact JSON stays inspectable even when it is invalid.
- 🧩 The selected configuration is kept whole: `dns`, `routing`, every outbound, `dialerProxy` chains, observatories, policy and reverse sections all survive.
- 🔗 The chosen item is pinned by SHA-256, so a provider reordering the array does not silently switch servers.
- ✅ Atomic activation: a candidate replaces the running configuration only after `xray run -test` succeeds over the final `confdir`.
- ♻️ An unchanged subscription leaves Xray running, so a scheduled refresh does not drop connections.
- ↩️ Rollback to the last good source and runtime on transport, JSON, Xray, or install failures.
- 🔀 REDIR + TPROXY, pure TPROXY, and REDIR + TUN interception, selected according to RouterOS kernel support.
- 🩺 Real HTTP health checks through the configuration's own outbounds, not a bare TCP connect.
- 🌍 Geodata bootstrapped before the core starts, then refreshed by Xray's own scheduler.
- 🎨 Built-in WebUI on port `80` with colour themes, no Clash API and no external dashboard.
- 🔐 HTTP Basic Auth with an in-app sha512crypt hash generator; no password is shared between installations.
- 💾 Profiles persist under `/etc/xray`; generated configurations, jobs, events and geodata stay in `/dev/shm`.
- 🌐 `amd64`, `arm64`, `armv7` and `armv5` images.

## 🚦 Lifecycle

1. Add a URL that returns a JSON array of complete Xray configurations. Saving a new or changed URL starts a download automatically.
2. Remnawave headers, global and optionally per-profile, are sent with the request.
3. The response body is stored as received, then the selected item is pinned by its SHA-256 fingerprint.
4. Container fragments are merged through `-confdir`: geodata assets, log level, and the inbounds required by the interception mode.
5. The candidate is validated with `xray run -test` and becomes the runtime configuration only when validation succeeds.
6. A failed update never stops a previously valid running configuration.
7. The selected subscription and the run/stop state survive container restarts.

## ⚡ Quick Docker Start

```bash
docker run -d \
  --name xray-remnasub-ros \
  --restart unless-stopped \
  --cap-add NET_ADMIN \
  --device /dev/net/tun \
  -p 8080:80 \
  -v ./xray-remnasub:/etc/xray \
  -e BASIC_AUTH_USER=admin \
  -e BASIC_AUTH_HASH='$1$replace$the-generated-hash' \
  ghcr.io/medium1992/xray-remnasub-ros:latest
```

Open `http://127.0.0.1:8080/`.

Generate the hash with `openssl passwd -1 'replace-with-a-long-password'`, or from the panel's "Access" tab, which produces the stronger sha512crypt.

When `BASIC_AUTH_HASH` is unset the container does not fall back to a password shared by every installation. It generates a random one on each start and prints it to the container log (`/log/print` on RouterOS, `docker logs` locally). That password changes on every restart, so set `BASIC_AUTH_HASH` for a permanent installation.

## 🛠 RouterOS Installation

> The example uses RouterOS 7.21+ `mountlists` and `envlists` syntax. Adjust disk paths and addresses for your router.

Enable containers in device mode on a new router first:

```routeros
/system/device-mode/print
/system/device-mode/update mode=advanced container=yes
```

```routeros
/interface/veth/add name=XrayRemnaSub address=192.168.255.14/30 gateway=192.168.255.13
/ip/address/add address=192.168.255.13/30 interface=XrayRemnaSub
/container/mounts/add list=xray-remnasub-ros src=usb1/xray-remnasub dst=/etc/xray
/container/envs/add list=xray-remnasub-ros key=BASIC_AUTH_USER value=admin
/container/envs/add list=xray-remnasub-ros key=BASIC_AUTH_HASH value="\$1\$salt\$replace-with-your-digest"
/container/config/set registry-url=https://ghcr.io tmpdir=usb1/pull
/container/add remote-image=ghcr.io/medium1992/xray-remnasub-ros:latest interface=XrayRemnaSub root-dir=usb1/xray-remnasub-root mountlists=xray-remnasub-ros envlists=xray-remnasub-ros logging=yes start-on-boot=yes comment=XrayRemnaSub
```

Route selected clients through the container:

```routeros
/routing/table/add name=XrayRemnaSub fib
/ip/route/add dst-address=0.0.0.0/0 gateway=192.168.255.14 routing-table=XrayRemnaSub check-gateway=ping comment=XrayRemnaSub
/routing/rule/add src-address=192.168.88.100/32 action=lookup-only-in-table table=XrayRemnaSub comment="XrayRemnaSub client"
```

The container blocks gateway ICMP until Xray and the interception rules are ready, so `check-gateway=ping` gives fail-closed route health. Open the UI at `http://192.168.255.14/`.

## 🧾 Subscription Model

This container consumes JSON subscriptions only. The response root must be a JSON array, and every array item is one complete Xray configuration:

```json
[
  {
    "remarks": "Server A",
    "dns": {},
    "routing": {},
    "outbounds": []
  },
  {
    "remarks": "Server B",
    "outbounds": []
  }
]
```

The container does not extract the first proxy outbound and does not synthesize a shared balancer. The selected item keeps its `dns`, `routing`, all `outbounds`, `proxySettings`/`dialerProxy` chains, observatories, policy, reverse configuration, and other native Xray fields.

Later `confdir` fragments only add:

- the managed asset directory and default geodata when needed;
- the local log level;
- mixed port `1080` and the inbounds required by the interception mode.

Source inbounds are retained. Port conflicts with `80`, `1080`, REDIR, or TPROXY must be fixed in the subscription template.

Container-managed inbound tags are stable and reserved:

| Tag | Used by |
|---|---|
| `xray-remnasub-mixed` | mixed inbound in every mode |
| `xray-remnasub-tproxy` | combined TCP/UDP inbound in `tproxy` mode |
| `xray-remnasub-tcp` | TCP REDIR in `redir-tproxy` and `redir-tun` modes |
| `xray-remnasub-udp` | UDP TPROXY in `redir-tproxy` mode |
| `xray-remnasub-tun` | TUN in `redir-tun` mode |

The container does not rewrite `routing.rules[].inboundTag`. Rules without `inboundTag` continue to apply to every inbound. A rule containing a source inbound tag remains scoped to that source inbound; list the required tags from the table in the subscription template to target RouterOS traffic. A source inbound using a reserved tag is rejected so that a later `confdir` fragment cannot replace it silently.

An authoritative empty response, HTTP `401/403/404/410/451`, or an explicit HWID restriction disables the active runtime. Transport errors, timeouts, `5xx`, malformed JSON, and invalid Xray configurations retain the last-good version.

## 📨 Request Headers

Remnawave picks the subscription format from the `User-Agent`, so the container sends a client header set by default: `x-hwid`, `x-device-os`, `x-ver-os`, `x-device-model` and `user-agent`. A value you set explicitly always wins over the substituted one.

The "Default headers" switch on the Requests tab turns that substitution off entirely. With it off, only the headers you entered yourself are sent: the panel drops untouched defaults from the list and keeps the ones you edited. This matters when a provider expects its own header set, or when a foreign `User-Agent` gets in the way.

Per-profile headers take precedence over the global ones. Toggling the switch, like editing the headers themselves, triggers a fresh download of the active subscription, because the request is now a different one.

## ♻️ Core Restarts

A scheduled refresh that returns the same subscription does not restart Xray. Before publishing a candidate the container compares it with the running version: the subscription fragment, the container's own fragments, the configuration set, the listener metadata, the source digest, and the geodata asset key. When all of them match, the candidate is discarded, `configuration unchanged` is written to the event log, and established connections survive.

The comparison covers the whole subscription response, so a provider changing an item you have not selected still counts as a change and does restart the core.

## 🌍 Geodata

Xray refreshes geodata itself. Its built-in scheduler honours `geodata.cron`, downloads through `geodata.outbound`, replaces the files transactionally, and hot-reloads them without a restart. The container does not touch an asset set that a running core owns.

What the container does own is the gap Xray leaves: if an asset file does not exist when the core starts, Xray neither downloads nor creates it — it simply fails to parse the configuration. So the container bootstraps missing assets before `xray run -test`, and only that. An existing file is never re-downloaded and never even touched.

When the selected JSON already has `geodata`, its cron, assets and outbound are preserved. Otherwise the container adds the Loyalsoldier `geoip.dat` and `geosite.dat` releases with schedule `0 4 * * *` and outbound `direct`. If `direct` is unavailable or belongs to a non-`freedom` outbound, a tagged `freedom` is reused or a dedicated helper is appended without changing the original outbound order.

Loyalsoldier URLs are verified against their adjacent `.sha256sum` files. Custom assets must use HTTPS, a safe relative path, and stay under 128 MiB per file.

| Storage | Directory | Behaviour |
|---|---|---|
| `memory` | `/dev/shm/xray-remnasub/geodata/<hash>` | Default. Avoids large flash writes; assets disappear on container restart and are bootstrapped again. |
| `persistent` | `/etc/xray/remnasub/geodata/<hash>` | Keeps assets on the mounted drive across restarts. |

Memory is the default on purpose. Router flash is typically small, and roughly 20 MB of geodata rewritten on every update is a poor trade for it, so writing to disk stays a deliberate choice.

The asset directory is pinned with `xray.location.asset` and an explicit `geodata.assets[].path`, so Xray reads exactly the managed files. If the same asset name also exists in `/usr/local/share/xray`, `/usr/share/xray`, or `/opt/share/xray`, the container reports a warning rather than letting the shadowed copy pass unnoticed.

## 🩺 Health Checks

Health checks perform an HTTP request through the real outbound rather than a TCP connect to the server address. Parameters are selected in this order:

1. matching `burstObservatory.pingConfig`;
2. matching `observatory`;
3. the URL, timeout, and method configured in the container UI.

A short-lived isolated Xray keeps the full outbound array, so `sockopt.dialerProxy`, `proxySettings.tag`, and related dependencies continue to work. Check-all runs sequentially to limit RouterOS load.

## 🔀 Interception Modes

| Mode | TCP | UDP | Backend |
|---|---|---|---|
| `auto` | REDIR | TPROXY when supported, otherwise TUN | kernel capability probe |
| `redir-tproxy` | REDIR `12345` | TPROXY `12346` | nftables |
| `tproxy` | TPROXY `12346` | TPROXY `12346` | nftables |
| `redir-tun` | REDIR `12345` | `Xray` TUN | nftables or iptables-legacy |

If nftables is available but kernel TPROXY support is missing, `amd64` and `arm64` use nftables with REDIR + TUN. Kernels without nftables, plus `armv7` and `armv5`, use iptables-legacy. Cleanup only removes container-owned tables, chains, routes, and policy rules.

MPTCP cannot be intercepted, so both backends drop TCP option 30 on the LAN interface and clients fall back to plain TCP. nftables does this in its own chain; iptables uses `mangle` `PREROUTING`, because `DROP` is not allowed in the `nat` table.

Alpine normalizes the standard rules to `local=0`, `main=32766`, and `default=32767`. TPROXY adds `fwmark 1` in table `100` at priority `100`. TUN uses table `110` and priorities `10000..10005`.

## 💾 Storage

`/etc/xray/remnasub` contains profiles, source subscriptions, response metadata, and — only when explicitly enabled — persistent geodata. Everything generated at runtime lives in `/dev/shm/xray-remnasub`: confdirs, status, jobs, events, logs, and memory geodata. That split is deliberate: the router's flash is small, and the container is built to leave it alone unless the user opts in.

## 🛡 Security

Subscription files contain credentials. Keep `/etc/xray` private, retain Basic Auth on untrusted networks, and use a unique long password. The container does not add or expose an Xray API itself; API and inbound sections supplied by the selected full JSON are retained, so control the subscription template.

## 🩻 Diagnostics

```sh
cat /dev/shm/xray-remnasub/events.log
cat /dev/shm/xray-remnasub/network.log
ip rule show
ip route show table 100
ip route show table 110
nft list tables
```

## 🐳 Build

```bash
docker buildx build \
  --platform linux/arm64 \
  --build-arg XRAY_VERSION=v26.7.28 \
  --provenance=false \
  --sbom=false \
  -t xray-remnasub-ros:v26.7.28-arm64 \
  --load .
```

Docker versions using the containerd image store may export an OCI layout that older RouterOS releases cannot import. Convert it to a legacy `docker-archive`:

```bash
skopeo copy --format v2s2 \
  docker-daemon:xray-remnasub-ros:v26.7.28-arm64 \
  docker-archive:xray-remnasub-ros-v26.7.28-arm64.tar:xray-remnasub-ros:v26.7.28
gzip -9 xray-remnasub-ros-v26.7.28-arm64.tar
```

A compatible archive contains `manifest.json`, `repositories`, and `*/layer.tar`, not `oci-layout` and `blobs/sha256/*`.

`armv5` has no Alpine base image, so that platform builds from `scratch` plus the Buildroot `rootfs.tar` tracked in this repository.
