# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [0.5.1]

### Security

- **`--lan` exposed every running app, not just the one you shared.** LAN mode
  is a property of the daemon — one proxy serves every project — so
  `run --lan` in one app made every other registered route answer the whole
  Wi-Fi too. Routes now record the opt-in (`lan: true`, set by `run --lan`) and
  the proxy serves *only* those to off-loopback clients; everything else 404s.
  Loopback access is unchanged. The gate fails closed: a peer address we can't
  read counts as remote. (Upstream portless has the same daemon-wide exposure
  and no per-route gating; this goes further deliberately.)
- **The 404 page listed your running apps to LAN clients.** The app listing
  added in 0.5.0 handed anyone on the network the name of every project you had
  running. Off-loopback clients now get a bare 404.

### Added

- **`proxy restart --no-lan`** — return the daemon to loopback-only without a
  `stop`/`start` dance. (`--lan`/`--no-lan` are both explicit now; a plain
  `restart` still preserves the current mode.) The warning printed when `run
  --lan` switches a loopback-only daemon over now says how to undo it.

## [0.5.0]

### Security

- **The proxy listened on all interfaces.** It bound `0.0.0.0`, so every
  registered dev app was reachable from the LAN, a VPN, or any other network
  the machine sits on — no opt-in. The proxy (and the :80 redirect listener)
  now binds the loopbacks only; `--lan` is the explicit opt-in, as a proxy
  mode: `rb-portless run --lan` switches a loopback-only daemon over
  automatically (persisted in a `proxy.lan` marker so restarts keep it), and
  `proxy start --lan` does it by hand. Upstream portless shipped the same
  change as a security fix.

### Fixed

- **HTTP/2 responses lost all headers and their body when the backend sent a
  hop-by-hop header.** A backend `Connection: close` (or `Transfer-Encoding`,
  `Keep-Alive`, …) was relayed verbatim into the h2 stream, where those headers
  are illegal — the header block aborted mid-write and the client saw a bare
  `200` with no headers and no body. The proxy now strips hop-by-hop headers
  from backend responses (like portless), except on a 101 h1 upgrade where they
  carry the WebSocket handshake.
- **IPv6-first clients got `ECONNREFUSED`.** `*.localhost` resolves to `::1` as
  well as `127.0.0.1`, but the proxy only bound IPv4 — clients without
  Happy-Eyeballs fallback couldn't connect. The proxy now also listens on the
  IPv6 loopback, best-effort (portless binds both).
- **Generated Rails URLs dropped the proxy port.** `X-Forwarded-Host` was
  stripped to the bare hostname, so whenever the proxy serves on a non-default
  port (e.g. the `:1355` sudo-declined fallback) `request.url` and every
  generated link pointed at the portless host *without* the port. The full
  authority is now forwarded, as in portless.
- **The railtie crashed apps without Action Cable.** The
  `portless.action_cable_origins` initializer touched `config.action_cable`
  unconditionally; API-only apps (or apps with trimmed railties) failed to boot
  with `NoMethodError`. Now guarded.
- **The railtie crashed apps that set `allowed_request_origins` to a bare
  Regexp** (idiomatic — Rails' own development default is one) or a frozen
  array: `concat` on it blew up boot. The origins list is now rebuilt with
  `Array(existing) + ours`.
- **A stale app-configured `:port` leaked into generated links.** With the
  common `config.action_mailer.default_url_options = { host: "localhost",
  port: 3000 }`, the railtie's merge kept `port: 3000` whenever the portless
  URL had no explicit port — every mailer link pointed at
  `https://<name>.localhost:3000`. The merge now drops `:port` unless the
  portless URL carries one.
- **Custom-tld subdomains beyond one label were 403'd.** Rails' leading-dot
  host shorthand (`.myapp.test`) matches a single subdomain label, so
  `a.b.myapp.test` failed host authorization while `a.b.myapp.localhost`
  passed. Custom tlds now use a multi-level regexp like `.localhost` does.
- **`--lan` devices hit Rails' blocked-host page.** The mDNS `<name>.local`
  host was never whitelisted (it's not in any Rails default, and PORTLESS_URL
  only carries the `.localhost` URL). `run --lan` now injects
  `PORTLESS_LAN_HOST`, and the railtie whitelists it and adds a matching
  Action Cable origin.
- **`--tailscale`/`--funnel` requests were rejected by Rails.** The tunnel
  forwards with the raw `*.ts.net` Host, which nothing whitelisted. The runner
  now injects `PORTLESS_TAILSCALE_URL`/`PORTLESS_NGROK_URL` (parity with
  portless), the railtie whitelists those hosts (+ Action Cable origins), and
  the proxy also routes requests addressed to a route's share hostname
  (upstream issue #297).
- **`clean` left the boot service installed** — a surviving launchd/systemd
  unit would resurrect the proxy against a deleted state dir. `clean` now
  uninstalls it (only when one exists), and both `clean` and `prune` tear down
  tailscale serve/funnel registrations recorded on (stale) routes.
- **A plain `proxy restart` reverted to defaults.** The daemon now records its
  TLS mode (like the LAN marker); `restart` preserves both unless
  `--tls`/`--no-tls`/`--lan` are passed, and a project whose `tls` setting
  disagrees with the running daemon gets a warning instead of silently
  spawning a rival proxy on the default port.
- **`clean`/re-trust cycles piled up CAs in the macOS keychain**
  (`remove-trusted-cert` clears the trust setting but keeps the cert) — the
  stale certificates are now deleted by CN.
- **Monorepo runs took over other projects' routes unconditionally** —
  `Multi` now honors `--force` like the single-app path.
- Hostname labels (names, worktree branch prefixes) are clamped to the 63-char
  DNS maximum — very long branch names produced invalid hostnames and
  over-long cert filenames.

### Changed

- **Non-interactive privileged starts fail loudly instead of silently moving
  to `:1355`.** When binding :443 needs sudo and there's no terminal (CI, task
  runners), `run` used to fall back to `:1355` — quietly changing every URL.
  It now exits with the ways out (pre-start the proxy, install the boot
  service, or set `PORTLESS_PORT`), matching portless.
- The proxy dials backends via `localhost` (both loopback families tried in
  sequence), so an IPv6-only dev server (a Node app bound to `::1`) no longer
  502s.
- The 404 page now lists the active apps (clickable) and the `rb-portless
  <name> <cmd>` command that would register the missing one.

### Added

- The `PORTLESS_*` env contract, parity with portless: `PORTLESS_HTTPS=0|1`
  forces TLS off/on, `PORTLESS_TLD` overrides the tld, `PORTLESS_APP_PORT`
  pins the backend port, and `PORTLESS_LAN` / `PORTLESS_NGROK` /
  `PORTLESS_TAILSCALE` / `PORTLESS_FUNNEL` enable the matching run flags.
  `PORTLESS_HOSTS_FILE` overrides the hosts-file path (tests, unusual
  setups). Env overrides beat portless.json; explicit CLI flags beat both.
- A 30s backend response-header timeout (504) so a backend that accepts and
  then hangs can't hold client connections forever, and an (mtime, size) cache
  for routes.json so the proxy no longer re-parses it on every request.
- `X-Forwarded-For` on proxied requests (the client loopback/LAN address), so
  `request.remote_ip` and request logs see the real client — parity with
  portless.
- `NODE_EXTRA_CA_CERTS` in the child env: Node dev servers ignore
  `SSL_CERT_FILE`, so Node-side outbound HTTPS to portless hosts now trusts the
  local CA too (an existing value is respected).
- **End-to-end test suite** (`test/e2e_*_test.rb`), modeled on portless's
  `tests/e2e`: boots the real proxy daemon on a high port plus live backends
  and covers TLS/SNI cert verification, wildcard tenant subdomains,
  `X-Forwarded-*`, HTTP/2, the full WebSocket relay, live route reloads,
  404/502 pages, the daemon lifecycle (detached start → discovery → stop),
  `run` (register → serve → deregister, process-group kill of a grandchild,
  exit-status propagation), `PORTLESS=0` bypass, monorepo multi-app runs,
  `prune` reaping an orphaned dev server, route-store lock contention across
  processes — and a real Rails app booted with the railtie (host
  authorization, `default_url_options`, mailer defaults, Action Cable
  origins). Rails-stack gems are test-only.

## [0.4.1]

### Fixed

- **Proxied apps could no longer verify public TLS certificates.** `run` set the
  child's `SSL_CERT_FILE` to our local CA so the app would trust sibling
  `.localhost` hosts — but that env var *replaces* OpenSSL's trust store rather
  than extending it, so the app lost every public root and all outbound HTTPS
  (payment APIs, S3, webhooks, exchange-rate feeds…) failed with `certificate
  verify failed (unable to get local issuer certificate)`. `run` now hands apps
  a combined bundle (the system's default roots **plus** our CA), assembled once
  into `~/.rb-portless/ca-bundle.pem` and rebuilt when either input changes, so
  apps trust the public web *and* our local hosts. Falls back to leaving
  `SSL_CERT_FILE` unset when the CA or system roots can't be located.

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
