# RemnaSub Xray RoS

An Xray-core subscription container for MikroTik RouterOS. It accepts a Remnawave/Happ subscription as an array of complete Xray JSON configurations, lets the user select one item, and runs it with small local fragments required for RouterOS traffic interception.

## Features

- multiple subscription profiles;
- unchanged persistent source responses;
- complete-configuration selection preserved by SHA-256 fingerprint;
- final `confdir` validation with `xray run -test` before activation;
- last-good source/runtime rollback on transport, JSON, Xray, or install failures;
- manual and scheduled subscription refresh;
- REDIR + TPROXY, pure TPROXY, and REDIR + TUN;
- real HTTP health checks through the configuration's Xray outbounds;
- pre-start geodata bootstrap and missed-schedule catch-up;
- built-in web UI without Clash API or an external dashboard;
- `amd64`, `arm64`, and `arm/v7` images.

The initial web credentials are `admin` / `admin`. Change them before permanent use.

## Subscription model

The response root must be a JSON array. Every array item is one complete Xray configuration, matching Happ semantics:

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

## Geodata

When the selected JSON already has `geodata`, its cron, assets, and outbound are preserved. Otherwise the container adds the Loyalsoldier `geoip.dat` and `geosite.dat` releases with schedule `0 4 * * *` and outbound `direct`. If `direct` is unavailable or belongs to a non-`freedom` outbound, a tagged `freedom` is reused or a dedicated helper is appended without changing the original outbound order.

Missing assets in an unused asset set are downloaded before `xray run -test`, so the container performs this bootstrap directly. A missing asset download failure rejects the candidate. Before starting Xray for an unused set, the container also checks existing files for cron occurrences missed since their `mtime`; a failed refresh keeps the old file and exposes a warning.

Exact Loyalsoldier URLs are verified with their adjacent `.sha256sum` files. Custom assets must use HTTPS, a safe relative path, and remain under 128 MiB per file.

| Storage | Directory | Behavior |
|---|---|---|
| `memory` | `/dev/shm/xray-remnasub/geodata/<hash>` | Default. Avoids large flash writes; assets disappear on container restart and are downloaded again. |
| `persistent` | `/etc/xray/remnasub/geodata/<hash>` | Keeps assets on the mounted drive and catches missed updates on the next start. |

While an asset set is used by the running Xray or an HTTP health check, container jobs do not modify it. Xray's native scheduler is the only writer for an active set: it honors `geodata.outbound`, updates, and hot-reloads the files. After the core fully exits, the container may bootstrap or catch up a missed cron before the next start.

## Health checks

Health checks perform an HTTP request through the real outbound rather than a TCP connect to the server address. Parameters are selected in this order:

1. matching `burstObservatory.pingConfig`;
2. matching `observatory`;
3. the URL, timeout, and method configured in the container UI.

A short-lived isolated Xray keeps the full outbound array, so `sockopt.dialerProxy`, `proxySettings.tag`, and related dependencies continue to work. Check-all runs sequentially to limit RouterOS load.

## Network modes

| Mode | TCP | UDP | Backend |
|---|---|---|---|
| `auto` | REDIR | TPROXY when supported, otherwise TUN | kernel capability probe |
| `redir-tproxy` | REDIR `12345` | TPROXY `12346` | nftables |
| `tproxy` | TPROXY `12346` | TPROXY `12346` | nftables |
| `redir-tun` | REDIR `12345` | `Xray` TUN | nftables or iptables-legacy |

If nftables is available but kernel TPROXY support is missing, `amd64` and `arm64` use nftables with REDIR + TUN. Kernels without nftables, plus `arm/v7`, use iptables-legacy. Cleanup only removes container-owned tables, chains, routes, and policy rules.

Alpine normalizes the standard rules to `local=0`, `main=32766`, and `default=32767`. TPROXY adds `fwmark 1` in table `100` at priority `100`. TUN uses table `110` and priorities `10000..10005`.

## RouterOS example

The example uses the RouterOS 7.21+ `mountlists` and `envlists` syntax. Enable containers in device mode on a new router first:

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

The container blocks gateway ICMP until Xray and interception rules are ready, so `check-gateway=ping` provides fail-closed route health. Open the UI at `http://192.168.255.14/`.

## Docker

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

Generate the password hash with `openssl passwd -1 'replace-with-a-long-password'`,
or from the panel's "Access" tab, which produces the stronger sha512crypt.

When `BASIC_AUTH_HASH` is unset the container does not fall back to a password
shared by every installation. It generates a random one on each start and prints
it to the container log (`/log/print` on RouterOS, `docker logs` locally). That
password changes on every restart, so set `BASIC_AUTH_HASH` for a permanent
installation.

## Build and RouterOS archive

```bash
docker buildx build \
  --platform linux/arm64 \
  --build-arg XRAY_VERSION=v26.7.28 \
  --provenance=false \
  --sbom=false \
  -t xray-remnasub-ros:v26.7.28-arm64 \
  --load .
```

Docker versions using the containerd image store may export an OCI layout that older RouterOS releases cannot import. Convert it to a legacy `docker-archive`, for example:

```bash
skopeo copy --format v2s2 \
  docker-daemon:xray-remnasub-ros:v26.7.28-arm64 \
  docker-archive:xray-remnasub-ros-v26.7.28-arm64.tar:xray-remnasub-ros:v26.7.28
gzip -9 xray-remnasub-ros-v26.7.28-arm64.tar
```

A compatible archive contains `manifest.json`, `repositories`, and `*/layer.tar`, not `oci-layout` and `blobs/sha256/*`.

## Storage and diagnostics

`/etc/xray/remnasub` contains profiles, source subscriptions, response metadata, and persistent geodata. Runtime confdirs, status, logs, and memory geodata live under `/dev/shm/xray-remnasub`.

Useful diagnostics inside the container:

```sh
cat /dev/shm/xray-remnasub/events.log
cat /dev/shm/xray-remnasub/network.log
ip rule show
ip route show table 100
ip route show table 110
nft list tables
```

Subscription files contain credentials. Keep `/etc/xray` private, retain Basic Auth on untrusted networks, and use a unique long password. The container does not add or expose an Xray API itself; API/inbound sections supplied by the selected full JSON are retained, so control the subscription template.
