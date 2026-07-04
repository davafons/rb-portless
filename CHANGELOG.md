# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [0.4.0]

### Added

- **Stale-proxy detection + `proxy restart`.** The proxy daemon outlives gem
  updates, so a `bundle update` could leave last week's code holding :443
  indefinitely. The proxy now stamps its version on every response (the health
  header carries `VERSION` instead of a bare `1`), and `run` compares it with
  the loaded gem: an older proxy prompts `restart the proxy? [Y/n]` (warn-only
  without a TTY); a *newer* proxy warns that the project's gem is the stale
  side. `rb-portless proxy restart` does the stop → wait → start dance manually,
  and the startup banner always prints both sides (`v0.4.0 · proxy v0.4.0`) so a
  drifting daemon is visible at a glance.

- **`default_url_options` under portless.** The Rails integration now points
  `config.action_mailer.default_url_options` and the router's default URL
  options at `https://<name>.localhost` whenever the app runs under rb-portless
  (dev only). Mailers and jobs — which build links without a request — stop
  emitting stale `localhost:<port>` URLs, so apps no longer need to hardcode a
  dev host. Untouched when not running under rb-portless.
- **Action Cable origin allow-listing under portless.** The integration adds the
  portless host and its subdomains to `config.action_cable.allowed_request_origins`
  (dev only), so a WebSocket handshake from `https://<name>.localhost` isn't
  rejected and Cable connects without extra config.

### Fixed

- **HTTP/2 cookie splitting corrupted the session.** Browsers speaking HTTP/2
  may send one `cookie` header field per cookie (RFC 9113 §8.2.3); the proxy
  forwarded them as repeated HTTP/1.1 `cookie:` lines, which the backend
  (e.g. Puma) joins with `", "`. Rack then parses that single mangled field and
  every cookie but the first is lost — silently emptying the Rails session and
  breaking CSRF on every form POST. The proxy now concatenates split cookie
  fields into one `"; "`-joined header, as an h2→h1 intermediary must.
- **WebSockets from HTTP/2 browsers never reached the backend.** Firefox (and
  any client using RFC 8441) opens `wss://` as an h2 *extended CONNECT* with
  `:protocol: websocket`; the proxy forwarded the CONNECT verb raw, which the
  HTTP/1.1 backend rejects as a parse error — Action Cable / Turbo Streams were
  dead through the proxy. The proxy now translates: forwards it as `GET` +
  `Upgrade` with a synthesized `Sec-WebSocket-Key` (extended CONNECT carries no
  nonce, h1 backends demand one), and maps the backend's `101 Switching
  Protocols` back to the `200` h2 requires. Verified end-to-end: an h2 extended
  CONNECT through the old proxy → 400, through the fixed proxy → 200 with
  Action Cable's welcome frame relayed.
- **A failed second `proxy start` left the live daemon unstoppable.** The
  latecomer overwrote the running daemon's pid/port marker files, then deleted
  them in its own crash cleanup — after which `proxy stop` claimed no proxy was
  running while a (often root-owned) daemon still held the port. A foreground
  start now refuses the port when a proxy already answers on it, cleanup only
  reaps markers the exiting process owns, and `proxy stop` falls back to
  port-owner discovery (re-trying under sudo for a root daemon) when the
  markers are gone.

## [0.3.1]

### Changed (internal — no behaviour change)

- **Deduped the two run paths.** `Runner` and `Multi` shared three methods
  (`child_env`, `display_url`, `ensure_trusted`); they now live in a `RunSupport`
  mixin. Multi-app mode picks up the actionable first-run CA-trust hints the
  single-app path already had.
- **Dropped dead code** — `CLI#todo`, the unread `Config#script`/`DEFAULT_SCRIPT`,
  `State.ca_serial` (no on-disk serial; the native CA sets it on the cert), and
  `Hosts.managed_hostnames` (no caller).

## [0.3.0]

### Fixed / hardened

- **Health probes can't hang.** Added a read timeout to the TLS and plain probes
  so a port that accepts but never answers no longer blocks `discover_port`.

### Added

- **Risky-TLD warning.** Warn when the configured `tld` ends in a real/reserved
  TLD (`dev`, `app`, `local`, …) that could intercept live traffic.
- **More tests** — `Proxy#call` is now public, so the proxy's routing + error
  logic is unit-tested (404 / 508 loop guard / 502 dead-backend, all stamped with
  the health header) plus health probes and privilege logic (42 tests). The
  successful byte-forward + **WebSocket upgrade relay** (ActionCable) need a live
  reactor and are verified end-to-end manually — async-http servers can't be torn
  down in-process without deadlock.


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
