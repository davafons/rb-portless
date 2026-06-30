# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Phase 1 — core.** `portless-rb run <cmd>` runs a dev server behind a local
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
