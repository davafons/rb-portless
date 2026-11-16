# AGENTS.md — rb-portless

A native-Ruby port of Vercel's **portless** (upstream clone: `references/portless`,
gitignored; `git clone https://github.com/vercel-labs/portless references/portless`).
This file is the map; read it before changing things.

## Goal: exact parity, nothing more

rb-portless does exactly what upstream portless does — same commands, flags, env vars,
config schema, routing, JSON shapes, exit codes, and output (with `portless` →
`rb-portless` in command examples). No rb-portless-only features: project-specific
needs (Rails tenant subdomains, etc.) live in a separate project. When the two
differ, match upstream. Port upstream changes by reading the TS function first and
writing the Ruby one with the same name in snake_case, so the two stay diffable.

Deliberate divergences (naming only, so both tools coexist):

- Executable/gem `rb-portless`, Ruby module `Portless`.
- State dir `~/.rb-portless` (`PORTLESS_STATE_DIR` overrides). File names inside it
  match upstream.
- Hosts block markers `# rb-portless-start/end`; service ids `rb.portless.proxy` /
  `rb-portless.service`; CA common name and page footer say "rb-portless".
- The child env also gets `SSL_CERT_FILE` (system roots + local CA, `ca_bundle.rb`) under
  the same conditions as `NODE_EXTRA_CA_CERTS` — the Ruby analogue, so Ruby clients
  trust sibling `.localhost` HTTPS apps.
- The child runs in `Bundler.unbundled_env` (plumbing, not a feature).

Known limits of the async-http stack (not choices; don't "fix" them by hand-rolling HTTP):
empty responses carry `content-length: 0` and no `connection: keep-alive`; a rejected
WebSocket upgrade gets async-http's own `connection: close` instead of the backend's;
"socket hang up" is ECONNRESET/EPIPE/EOF/`Protocol::HTTP::RefusedError`.

Not ported (yet): Windows CA trust + Task Scheduler service, the legacy `/tmp/portless`
state migration.

Agent skills (`skills/`) are upstream's `skills/portless` and `skills/oauth`, rewritten
for Ruby/Rails as `rb-portless` and `rb-portless-oauth` (different names so they install
next to upstream's). Same section order as upstream; keep behaviour claims in sync with
the code, and port upstream skill edits when you port the feature they describe.

## Versioning

The version mirrors the upstream release we match, plus a fourth segment for our own
fixes: `0.17.0.0` = parity with upstream 0.17.0, `0.17.0.1` = first local fix on top.
Only claim an upstream version once its features are in.

## Core mechanisms (upstream invariants)

- **No daemon IPC.** Coordination is files in the state dir: `routes.json` (upstream
  `RouteMapping` array, camelCase keys, written atomically under a `mkdir` lock; dead
  owners filtered on read, kept as `retired` for `prune`), plus the `proxy.*` markers
  (`pid`, `port`, `start`, `tls`, `tlds`, `lan` = LAN IP, `unprivileged`,
  `custom-cert`, `hosts-sync-token`). The daemon polls `routes.json` (upstream:
  `fs.watch`).
- **Privileged ports.** Probe-bind first; only on `EACCES` re-run under
  `sudo env PORTLESS_*=…`. Declined sudo exits with a recovery command (no fallback
  port). `--unprivileged` binds without sudo and accepts loopback peers only.
- **Health header** `X-Portless: 1` on every response; a probe for it tells our proxy from
  any other process on the port. Loops are counted with `x-portless-hops` (508 at 5).
- **Routing** is strict by default; `--wildcard` falls back to the most specific
  registered parent. Hosts outside the configured TLDs get 421.
- **Per-host SNI certs**, minted only for names under the configured TLDs, cached on
  disk and in memory.
- **Loopback by default.** `--lan` makes LAN a proxy mode: binds `0.0.0.0` + `::`,
  forces `.local`, publishes every route over mDNS, re-checks the LAN IP every 5 s.
- **State-dir safety.** Commands refuse a state dir another user can change; root-side
  writes never follow symlinks.

## Module map (`lib/portless/`)

| File | Upstream source |
| --- | --- |
| `cli.rb`, `commands.rb`, `help.rb` | cli.ts dispatch, commands.ts, help text |
| `args.rb` | args.ts (strict flag parsing, `UsageError` → exit 2) |
| `utils.rb` | utils.ts / cli-utils.ts shared helpers (ports, URLs, TLDs, env) |
| `config.rb`, `auto.rb` | config.ts, auto.ts (name inference, worktree prefix) |
| `workspace.rb`, `turbo.rb`, `multi.rb` | workspace.ts, turbo.ts, multi-app run |
| `runner.rb`, `run_support.rb`, `process_group.rb` | cli.ts runApp, child env, spawn/signals |
| `frameworks.rb`, `free_port.rb` | cli-utils.ts port/host injection, findFreePort |
| `route_store.rb` | routes.ts |
| `proxy.rb`, `pages.rb`, `fonts.rb` | proxy.ts, pages.ts, fonts.ts |
| `certs.rb`, `trust.rb`, `ca_bundle.rb` | certs.ts (+ Ruby CA bundle) |
| `daemon.rb` | cli.ts handleProxy/stopProxy/ensureProxyRunning, cli-utils.ts discoverState |
| `state.rb`, `privilege.rb`, `port_owner.rb` | utils.ts state dir + safety, elevation, port owners |
| `health.rb` | cli-utils.ts proxy probes |
| `hosts.rb`, `hosts_sync_auth.rb` | hosts.ts, hosts-sync-auth.ts |
| `lan_ip.rb`, `mdns.rb` | lan-ip.ts, mdns.ts |
| `tunnel.rb`, `cloudflare.rb`, `share/tailscale.rb` | tunnel.ts (ngrok), cloudflare.ts, tailscale.ts |
| `service.rb` | service.ts (launchd/systemd) |
| `clean_utils.rb`, `doctor.rb` | clean-utils.ts, cli.ts doctor |
| `mcp.rb` | mcp.ts |
| `compose.rb` | compose.ts |

## Conventions

- Stdlib-first; runtime deps are `async` + `async-http` (h1/h2/TLS/WebSocket).
- Minitest in `test/`. `test_helper.rb` points `HOME` and `PORTLESS_STATE_DIR` at a temp
  dir and puts shims for `security`/`sudo`/`certutil` first on `PATH`, so no test can touch
  `~/.rb-portless`, the keychain, or `/etc/hosts`. Never undo that in a test. Port upstream's unit tests
  alongside the code. The e2e layer (`test/e2e_helper.rb`) runs the real daemon on a
  free high port with `--skip-trust` and `PORTLESS_SYNC_HOSTS=0` (no sudo, no keychain,
  no `/etc/hosts`).
- Use jj in this repo (see the user's global instructions).
