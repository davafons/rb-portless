# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
[Semantic Versioning](https://semver.org/).

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
