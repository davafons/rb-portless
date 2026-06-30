# AGENTS.md — rb-portless

A native-Ruby port of Vercel's **portless** (`references/portless`, a Node/TS
monorepo). Goal: feature parity, HTTPS by default, framework-agnostic (Rails is
the first test target). This file is the map; read it before changing things.

## What it does

`rb-portless run <cmd>` runs a dev server through a local reverse proxy reachable
at `https://<name>.localhost` — no port numbers. A random backend port is
injected as `PORT`; the proxy routes the named host to it.

## Core mechanisms (ported from portless — keep these invariants)

- **No daemon IPC.** All coordination is files in `~/.rb-portless` (overridable
  via `PORTLESS_STATE_DIR`): `routes.json` (host→port→pid) under a `mkdir` lock,
  plus `proxy.pid`/`proxy.port`/CA files. The proxy watches `routes.json`.
- **Privileged port = re-exec under sudo.** For ports < 1024, re-run the CLI via
  `sudo env PORTLESS_*=… ruby <cli> proxy start …`; the elevated process binds
  the socket and chowns state files back to `SUDO_UID`. Fall back to `:1355` if
  sudo is denied and no explicit port was given. Refuse in CI/no-TTY.
- **Health header.** Every proxied response carries `X-Portless-Rb`; a HEAD probe
  is how we tell *our* proxy from any other process on a port.
- **Wildcard routing.** A route `name.localhost` also serves `*.name.localhost`
  (exact match first, then `host.end_with?(".#{route}")`). Critical for
  subdomain-per-tenant apps (e.g. `*.shirabe.org.localhost`).
- **Per-host SNI certs.** `*.localhost` wildcard certs are invalid at the
  reserved-TLD boundary, so mint a leaf per hostname on the TLS SNI callback,
  cached on disk + in memory.

## Module map (`lib/portless/`)

| File | Role | portless source |
| --- | --- | --- |
| `constants.rb` | ports, thresholds, state-dir, header, markers | cli-utils.ts |
| `state.rb` | state-dir paths + chown-back-to-SUDO_UID | utils.ts |
| `config.rb` | portless.json + name/tld inference | config.ts, auto.ts |
| `free_port.rb` | random 4000–4999 finder (skip bad ports) | cli-utils.ts findFreePort |
| `route_store.rb` | routes.json + dir-lock + dead-pid reap | routes.ts |
| `health.rb` | X-Portless-Rb probe + discoverState | cli-utils.ts |
| `privilege.rb` | needs-sudo, sudo re-exec, 1355 fallback | cli.ts handleProxy |
| `hosts.rb` | /etc/hosts marked-block sync/clean | hosts.ts |
| `certs.rb` | OpenSSL CA + per-host SNI leaf certs | certs.ts |
| `trust.rb` | OS trust store install/remove | certs.ts trustCA |
| `proxy.rb` | async-http reverse proxy (h1/h2/tls/ws) | proxy.ts |
| `daemon.rb` | proxy start/stop, sudo bind, 1355 fallback | cli.ts handleProxy |
| `service.rb` | launchd / systemd boot service | service.ts |
| `frameworks.rb` | --port/--host injection (vite/astro/…) | cli-utils.ts |
| `banner.rb` | the "where's my app" startup banner | cli.ts (run output) |
| `multi.rb` | monorepo: run many apps under one proxy | workspace.ts/turbo.ts |
| `lan_ip.rb` / `mdns.rb` | LAN IP detect + `<name>.local` mDNS publish | lan-ip.ts/mdns.ts |
| `share/ngrok.rb` / `share/tailscale.rb` | public/tailnet sharing | ngrok.ts/tailscale.ts |
| `runner.rb` | run cmd: port→env→spawn→register→supervise | cli.ts runApp |
| `rails.rb` | opt-in railtie (whitelist *.localhost in dev) | — |
| `cli.rb` | command dispatch | cli.ts main |

## Status

- **Phase 0 ✅** scaffold + coordination layer (config, state, free_port,
  route_store, health, privilege, hosts) + CLI dispatch.
- **Phase 1 ✅** HTTPS proxy on async-http (TLS+SNI, h1+wildcard routing,
  X-Forwarded-*, loop guard), certs + macOS trust, runner, sudo bind + 1355
  fallback. **Verified against shirabe** at `https://*.shirabe.org.localhost`.
- **Phase 2 ✅** HTTP/2, full command surface (doctor/clean/prune/alias/get/hosts),
  boot service (launchd/systemd), daemon lifecycle.
- **Phase 3 ✅ (partial)** framework `--port`/`--host` injection, Linux CA trust,
  optional `portless/rails` railtie.

- **Phase 4 ✅** startup banner; monorepo multi-app (`apps` map); LAN mode
  (`--lan`: LanIp + mDNS `<name>.local`); public sharing (`--ngrok`/`--tailscale`/
  `--funnel`, experimental).

### Roadmap (not yet built)

- Windows CA trust + Task Scheduler service.
- WebSocket upgrade relay hardening + HTTP/2 to the backend.
- mDNS LAN-IP change monitoring (re-publish on network switch).

## Conventions

- Stdlib-first; the only runtime deps are `async` + `async-http` (for h1/h2/tls/ws).
- Minitest + fixtures-free tests in `test/`; isolate state via `PORTLESS_STATE_DIR`.
- Mirror portless's naming/structure so the two stay diffable against
  `references/portless`.
