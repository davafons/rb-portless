# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [0.3.0]

### Fixed / hardened

- **Health probes can't hang.** Added a read timeout to the TLS and plain probes
  so a port that accepts but never answers no longer blocks `discover_port`.

### Added

- **Risky-TLD warning.** Warn when the configured `tld` ends in a real/reserved
  TLD (`dev`, `app`, `local`, …) that could intercept live traffic.
- **More tests** — health probes and privilege logic. (Verified manually, since
  the Async proxy can't be driven in-process without deadlock: HTTP/HTTPS/HTTP-2
  forwarding, wildcard routing, and the **WebSocket upgrade relay** / ActionCable.)


- **Startup banner.** Running a dev server through rb-portless now prints a clear
  banner with the named URL(s) it's reachable at — not just `127.0.0.1:port`.
- **Monorepo / multi-app.** A `portless.json` `apps` map runs several apps under
  one proxy, each at its own `<name>.<tld>` (`rb-portless run` with no command).
- **LAN mode (`--lan`).** Reach the app from phones/tablets on the same Wi-Fi:
  detects the LAN IP, registers `<name>.local`, and publishes it over mDNS
  (`dns-sd`/`avahi-publish`). `--ip` overrides the detected address.
- **Public sharing (experimental).** `--ngrok`, `--tailscale`, `--funnel` expose
  the app via ngrok / your tailnet (their CLIs, installed separately). When a
  tool is missing or unconfigured, print an **actionable** message (install link,
  `ngrok config add-authtoken`, "enable HTTPS in your tailnet DNS settings",
  "run `tailscale up`") rather than failing silently — mirroring portless. Tailscale is **non-destructive**: it reads
  `tailscale serve status`, picks a free HTTPS port (never clobbering your
  existing serve/funnel config), registers with `--yes`, and removes only the
  port it created on exit — mirroring portless's port-conflict handling.

## [0.2.0]

### Added

- **Auto-trust on first run.** `run` now trusts the local CA automatically the
  first time (interactive only; skipped with a hint in CI), matching portless —
  HTTPS works with no browser warnings without a separate `trust` step.

## [0.1.0] — first release

The full portless workflow for Ruby, validated end-to-end against a real Rails
app (`rb-portless run bin/rails server` → `https://*.shirabe.org.localhost`).

### Added

- **HTTP/2** with HTTP/1.1 fallback (server-side ALPN negotiation).
- **Commands:** `run`, `proxy start|stop`, `trust`, `service install|uninstall|status`,
  `alias`, `get`, `list`, `hosts sync|clean`, `doctor`, `prune`, `clean`.
- **Boot service** — launchd (macOS) / systemd (Linux) for a no-prompt
  privileged bind at boot.
- **CA trust** on macOS (login keychain) and Linux (distro anchors).
- **Framework `--port`/`--host` injection** for Vite, Astro, Angular, etc.
- Optional **Rails railtie** (`gem "rb-portless", require: "portless/rails"`)
  that **auto-detects** when the app runs under `rb-portless` (via `PORTLESS_URL`)
  and only then whitelists the matching `*.localhost` dev hosts — zero-config,
  and a no-op when you run Rails normally.
- **Phase 1 — core.** `rb-portless run <cmd>` runs a dev server behind a local
  HTTPS reverse proxy reachable at `https://<name>.localhost`:
  - async-http TLS proxy with per-host SNI certs, Host + wildcard routing
    (`*.name.localhost` → the app registered as `name.localhost`), `X-Forwarded-*`
    headers, a loop guard, and a sibling `:80 → https` redirect.
  - Native-OpenSSL local CA + on-demand per-host leaf certs; macOS keychain trust.
  - `routes.json` registry (directory-lock + dead-pid reaping), `X-Portless-Rb`
    health probe, and proxy auto-start.
  - Privileged-port binding via one-time `sudo` re-exec, with a `:1355` fallback.
  - Random backend port (4000–4999) injected as `PORT`/`HOST`.
- **Phase 0 — scaffold.** Gem skeleton, config (`portless.json` + name/tld
  inference), state dir, CLI dispatch (`run`, `proxy`, `trust`, `list`, …).
