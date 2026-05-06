# CoinProxy

A self-hosted, multi-coin Stratum proxy with a built-in web dashboard.
Aggregate workers, route to upstream pools with automatic failover, and
monitor everything from a single page.

[![release](https://img.shields.io/badge/release-v1.0.0-blue.svg)](https://github.com/hivecassiny/coinproxy)
[![platform](https://img.shields.io/badge/platform-linux%20%7C%20openwrt-success.svg)](#platforms)

---

## What it does

CoinProxy sits between your miners and one or more mining pools. Miners
connect to your proxy on a single TCP/TLS port; the proxy authenticates
once with the upstream, multiplexes jobs to all connected workers,
adjusts each worker's difficulty independently (vardiff), and reports
shares back. If the active pool goes down, traffic transparently fails
over to a configured backup.

A single binary ships everything — the Stratum core, the upstream
manager, the persistence layer, the JSON-RPC frontend API, and the
embedded Vue web UI. No separate database. No npm runtime on the host.

## Features

- **Multiple coins** in one process: BTC, BCH, LTC out of the box
  (SHA256d + Scrypt).
- **Multiple proxies per coin**: each with its own listen ports, account,
  vardiff window, and pool list.
- **Primary / backup pools** with health checks, latency probes, and
  automatic failover.
- **Per-miner vardiff** with configurable target share interval, sliding
  window, min/max bounds.
- **Web UI** in Chinese and English: live hashrate, miner table, pool
  status, share charts, blocks history, system logs.
- **Real-time** via WebSocket — snapshot updates, pool events, and
  system log lines stream into the page.
- **History** persisted to disk — 10-minute samples across 30 days.
- **TLS Stratum + TLS web UI** with auto self-signed bootstrap if no
  cert is configured.
- **Self-update**: the dashboard polls the release repo, surfaces a
  banner when a newer version is available, downloads the verified
  binary, and lets the system service manager respawn the process.
- **Single static binary**, zero runtime dependencies on the host.

## Quick install

> Requires a Linux host with `systemd` or OpenWrt with `procd`, run as
> root. The script auto-detects the architecture and downloads the
> matching binary.

**Interactive menu (recommended):**

```sh
curl -fsSL https://raw.githubusercontent.com/hivecassiny/coinproxy/main/install.sh | sudo sh
```

**Non-interactive install:**

```sh
curl -fsSL https://raw.githubusercontent.com/hivecassiny/coinproxy/main/install.sh -o install.sh
sudo sh install.sh install
```

The installer will:

1. Download the latest binary for your architecture (`linux-amd64`,
   `linux-arm64`, `linux-arm`, or `linux-mipsle`).
2. Verify the binary against its published `sha256`.
3. Drop a minimal `config.yaml` into `/etc/coinproxy/`.
4. Register and start a systemd unit (or OpenWrt init script).

When it finishes, open `http://<your-host>:8088` in a browser. The first
visit goes through a one-time setup page where you create the admin
account.

## <a id="platforms"></a>Supported platforms

| Platform | Binary | Notes |
|---|---|---|
| `linux-amd64` | `coinproxy-linux-amd64` | x86_64 servers |
| `linux-arm64` | `coinproxy-linux-arm64` | Raspberry Pi 4/5, ARM servers, Apple silicon Linux VMs |
| `linux-arm`   | `coinproxy-linux-arm`   | ARMv7 routers, Pi Zero 2 W (`GOARM=7`) |
| `linux-mipsle`| `coinproxy-linux-mipsle`| OpenWrt MIPS routers (`GOMIPS=softfloat`) |

## Web UI

Default listen address: `:8088`.

| Page | What it shows |
|---|---|
| **Home** | Aggregate hashrate, system load, per-coin cards |
| **Coins** | Coin list, add/remove coins, edit each proxy via modal |
| **Coin overview** | Per-coin stats, all proxies under that coin |
| **Dashboard** | One proxy: hashrate, shares, blocks, active pool |
| **Miners** | Live worker table, version-rolling status, kick / set-difficulty |
| **Pools** | Per-pool stats, hashrate chart (1d / 7d / 30d), real-time pool log |
| **Blocks** | All found blocks with confirmations |
| **History** | Hashrate / miners / shares / network difficulty trends |
| **Logs** | System log stream with coin / proxy / level filters, search highlight, copy / export |
| **Settings** | Web listen, language, TLS, admin credentials, restart / update |
| **About** | Version, system info |

## Configuration

Layout under `/etc/coinproxy/`:

```
/etc/coinproxy/
├── config.yaml           # Global: web, log, data, security, auth
├── data/                 # Persisted blocks / snapshot / history
└── coins/
    └── <COIN>/
        └── <proxy>.yaml  # One file per proxy
```

`config.yaml` example:

```yaml
web:
  listen: ":8088"
  language: "en"
  # Optional TLS for the web UI
  # tls: { cert: "./web-cert.pem", key: "./web-key.pem" }
log:
  level: "info"            # debug | info | warn | error
data:
  dir: "/etc/coinproxy/data"
security:
  allow_external_miners: true   # false → bind 127.0.0.1 only
```

Per-proxy `coins/BTC/main.yaml`:

```yaml
listen:
  - ":3333"
# listen_tls:
#   - ":3334"
# tls:
#   cert: "./cert.pem"
#   key:  "./key.pem"
account:
  user: "your_pool_user.worker"
  password: "x"
session_id:
  bytes: 3                       # 3 bytes = 16M concurrent sessions
vardiff:
  enabled: true
  initial: 65536
  min: 64
  max: 1073741824
  target_seconds: 15
  window_shares: 30
  window_seconds: 300
pools:
  - name: "primary"
    url: "stratum+tcp://btc.f2pool.com:3333"
    priority: 1
  - name: "backup"
    url: "stratum+ssl://btc.f2pool.com:1314"
    priority: 2
    insecure: false
```

You can edit everything from the web UI — files are rewritten on save.

## Service management

**systemd:**

```sh
sudo systemctl status   coinproxy
sudo systemctl restart  coinproxy
sudo systemctl stop     coinproxy
sudo journalctl -u coinproxy -f
```

**OpenWrt:**

```sh
/etc/init.d/coinproxy {start|stop|restart|enable|disable}
logread -e coinproxy
```

**install.sh helpers** (any host):

```sh
sudo sh install.sh status
sudo sh install.sh restart
sudo sh install.sh logs
sudo sh install.sh update
sudo sh install.sh uninstall
```

## Self-update

CoinProxy periodically fetches `VERSION` from this repository's `main`
branch and compares it with the running binary. If a newer version is
published, the dashboard shows a banner near the top of every page:

> 🆙 New version available: **v1.0.1** (current v1.0.0)  [Update now]

Clicking **Update now** does the following on the server:

1. Re-checks `VERSION`.
2. Downloads `bin/<version>/coinproxy-<os>-<arch>` and its
   `.sha256` sidecar.
3. Verifies the SHA-256 digest of the downloaded binary.
4. Atomically replaces the running executable in place.
5. Sends `SIGTERM` to itself so the system service manager respawns
   the new version.

The browser auto-reloads after about 10 seconds.

If anything fails (network, signature, write-permission), the running
binary is untouched and an error toast is shown. Use
`sudo sh install.sh update` from the shell as a fallback.

## Build from source

```sh
git clone https://github.com/hivecassiny/coinproxy
cd coinproxy

# Frontend → embedded into internal/web/dist
( cd web/ui && npm ci && npm run build )

# Server binary
go build -trimpath \
  -ldflags "-s -w -X main.version=$(cat VERSION)" \
  -o coinproxy ./cmd/coinproxy

./coinproxy -config ./config -version
```

Cross-compile script that produces every published platform at once:

```sh
bash scripts/release.sh
ls release/bin/$(cat VERSION)/
```

## Releasing

For maintainers pushing to this repository:

```sh
# In the dev repo
echo "v1.0.1" > VERSION
bash scripts/release.sh

# Copy the assembled tree into a checkout of hivecassiny/coinproxy
cp -R release/* /path/to/coinproxy-release/
cd /path/to/coinproxy-release
git add . && git commit -m "Release v1.0.1" && git push
```

Once `main` advances, every running CoinProxy will see the new
`VERSION` within 6 hours and offer the in-place upgrade.

## License

TBD.
