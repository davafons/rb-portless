---
name: rb-portless
description: Set up and use rb-portless (the native-Ruby port of Vercel's portless) for named local dev server URLs (e.g. https://myapp.localhost instead of http://localhost:3000) in Ruby and Rails projects. Use when integrating rb-portless into a Rails/Ruby app, running bin/dev or bin/rails server through the proxy, configuring dev server names, working with .localhost domains, Rails "Blocked hosts" errors behind the proxy, or troubleshooting port/proxy issues.
---

# rb-portless

Replace port numbers with stable, named .localhost URLs. For humans and agents.
rb-portless is a native-Ruby port of Vercel's [portless](https://github.com/vercel-labs/portless)
with the same commands, flags, `PORTLESS_*` environment variables, `portless.json`
schema, and routing. Only the names differ, so both can be installed side by side.
Use whichever one the project already uses: `rb-portless` in Ruby/Rails projects (a
`Gemfile`, `bin/rails`, `bin/dev`), `portless` where scripts call it.

## Why rb-portless

- **Port conflicts**: `Address already in use - bind(2) for "127.0.0.1" port 3000` when two Rails apps both default to 3000
- **Memorizing ports**: which app is on 3000 vs 3001 vs 5000?
- **Refreshing shows the wrong app**: stop one server, start another on the same port, a stale tab shows the wrong content
- **Agents test the wrong port**: AI agents guess or hardcode the wrong port
- **Cookie/session clashes**: cookies on `localhost` bleed across apps, so signing in to one app signs you out of another
- **Hardcoded ports in config**: CORS allowlists, OAuth redirects, `default_url_options`, and `.env` files break when ports change
- **Git worktrees**: two checkouts of the same app need two URLs

## Installation

Install the gem globally (recommended):

```bash
gem install rb-portless
```

Requires Ruby 3.2+ on macOS or Linux. Do not add it to an app's `Gemfile` just to run
it; it is a machine-wide tool, like the proxy it starts.

## Quick Start

```bash
# Run your app (auto-starts the HTTPS proxy on port 443)
rb-portless run bin/dev
# -> https://<project>.localhost

# Or with an explicit name
rb-portless myapp bin/rails server
# -> https://myapp.localhost
```

The proxy auto-starts when you run an app. You can also start it explicitly with
`rb-portless proxy start`. Auto-start reuses the saved port, TLS, TLD, and LAN settings
only after the proxy exits unexpectedly. A normal `rb-portless proxy stop` clears them,
so the next start uses the flags and environment variables it is given. Explicit env
vars take priority.

In non-interactive environments (no TTY, or `CI=1`), rb-portless exits with a
descriptive error instead of prompting for sudo. Pre-start the proxy in a terminal, or
use `--unprivileged`.

## Integration Patterns

### Rails (recommended)

rb-portless gives the child a free port in `PORT` (4000-4999) and sets `PORTLESS_URL`
to the app's public URL. `bin/rails server` and Puma's generated `config/puma.rb`
(`port ENV.fetch("PORT", 3000)`) both read `PORT`, so no flags are needed:

```bash
rb-portless run bin/rails server   # -> https://myapp.localhost
rb-portless run bin/dev            # -> same, with Procfile.dev processes
```

For `bin/dev`, the web process must listen on `$PORT`. Rails' generated `bin/dev`
exports `PORT` and starts foreman, which gives the base port to the **first** entry in
`Procfile.dev` (later entries get `PORT+100`, `PORT+200`, ...), so keep `web:` first.
Writing `-p $PORT` in a later entry does not help: foreman has already shifted `$PORT`
for it. If `web:` can't be first, wrap only that entry instead and run plain `bin/dev`:
`web: rb-portless myapp bin/rails server`. foreman also reads `.env`, and a `PORT=3000`
there wins over the assigned port; remove it. Other process managers: check that the
web process actually ends up on `$PORT`; otherwise the proxy returns 502.

**Allowed hosts.** Rails' host authorization blocks hostnames it doesn't know (403,
"Blocked hosts: api.myapp.localhost"). Rails 8 allows `.localhost` and `.test` in
development by default, but a leading-dot entry matches **one** label only:
`myapp.localhost` passes, while `api.myapp.localhost`, worktree hosts
(`fix-ui.myapp.localhost`), and `--wildcard` tenants (`tenant1.myapp.localhost`) are
blocked. Allow the app's own domain, and any other TLD you use, in
`config/environments/development.rb`:

```ruby
config.hosts << ".myapp.localhost"      # api.myapp, fix-ui.myapp, tenant1.myapp, ...
config.hosts << /.+\.localhost/         # or: any depth under .localhost
config.hosts << ".local"                # LAN mode
config.hosts << ".local.example.dev"    # multi-segment TLD
```

**Generated URLs.** The proxy preserves `Host` and sets `X-Forwarded-Proto`,
`X-Forwarded-Host`, `X-Forwarded-Port`, and `X-Forwarded-For`, and Rails trusts them
from loopback. `request.base_url`, `*_url` helpers, redirects, `force_ssl`, and Action
Cable's same-origin check all see `https://myapp.localhost`. For URLs built outside a
request (mailers, jobs), read `PORTLESS_URL`:

```ruby
# config/environments/development.rb
if (url = ENV["PORTLESS_URL"])
  uri = URI(url)
  options = { host: uri.host, port: uri.port, protocol: uri.scheme } # Rails drops :443/:80
  config.action_mailer.default_url_options = options
  Rails.application.routes.default_url_options = options
end
```

Code that runs without rb-portless (`PORTLESS=0`, CI) keeps its defaults. With
`--no-tls`, turn `config.force_ssl` off: it redirects to an `https://` URL nothing serves.

**Several servers in one checkout.** Two `bin/rails server` processes in the same
directory share `tmp/pids/server.pid`, and the second exits ("A server is already
running"). Give each its own: `PIDFILE=tmp/pids/api.pid rb-portless api.myapp bin/rails server`.
Separate worktrees don't collide.

**Calling rb-portless from Ruby code.** Inside a bundled process (a rake task, an
initializer, anything under `bin/rails`), Bundler hides gems outside your Gemfile, so
shell out unbundled: `Bundler.with_unbundled_env { `rb-portless get api.myapp`.strip }`.

### Other Ruby servers

Anything that reads `PORT` works unchanged: Puma, Falcon, `rackup` (pass `-p $PORT`
if your version ignores it), Sinatra (`set :port, ENV.fetch("PORT", 4567)`), Hanami.
For a server that ignores `PORT`, pass it yourself:

```bash
rb-portless api sh -c 'bundle exec my-server --port "$PORT"'
```

### Configuration file

Use an optional `portless.json` (same file name and schema as upstream) to fix the name:

```json
{ "name": "myapp" }
```

```bash
rb-portless run bin/dev   # -> https://myapp.localhost
```

The name is otherwise inferred from `package.json`'s `"name"`, the git root, or the
directory name. Note that `script` and bare `rb-portless` (no command) refer to
`package.json` scripts: in a project without a `package.json`, bare `rb-portless` only
prints help, so always pass the command (`rb-portless run bin/dev`).

### Ruby apps with a JavaScript frontend or monorepo

All of upstream's JavaScript integration works too, for repos that mix Rails with a JS
app:

- Bare `rb-portless` runs the `"dev"` script from `package.json` through the detected
  package manager; arguments after `--` go to the script.
- At a workspace root (`pnpm-workspace.yaml` or `"workspaces"` in `package.json`) it
  starts every package with a `"dev"` script. One `portless.json` at the root can name
  them: `{ "apps": { "apps/web": { "name": "myapp" }, "apps/api": { "name": "api.myapp" } } }`.
  Without an `apps` map, hostnames follow `<package>.<project>.localhost`.
- With `turbo.json`, it delegates to Turborepo; set `"turbo": false` to spawn directly.
- Frameworks that ignore `PORT` (Vite, VitePlus, VitePress, Astro, React Router,
  Angular, Expo, React Native, Wrangler) get `--port` and, when needed, `--host`
  injected. A compound script (`&&`, `|`, `;`), an env prefix, or delegation to another
  script is left alone; set the port in the script yourself.
- Vite gets `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS`, so its host check accepts the
  proxy's hostnames.

### Multi-app setups with subdomains

```bash
rb-portless myapp bin/rails server             # https://myapp.localhost
rb-portless api.myapp bundle exec puma         # https://api.myapp.localhost
rb-portless admin.myapp bin/rails server       # https://admin.myapp.localhost
```

By default, only explicitly registered subdomains are routed (strict mode). Start the
proxy with `--wildcard` to let any subdomain of a registered route fall back to that app
(e.g. `tenant1.myapp.localhost` routes to `myapp`, handy for subdomain-based
multi-tenancy). Exact matches always take priority over wildcards. When several
registered routes are parents of the host, the most specific one wins
(`admin.api.myapp.localhost` routes to `api.myapp`, not `myapp`). Your app reads the
tenant from `request.subdomains` as usual. Allow the deeper hosts in Rails
(`config.hosts << ".myapp.localhost"`, see Allowed hosts above).

### Git worktrees

`rb-portless run` detects git worktrees. In a linked worktree, the branch name is
prepended as a subdomain so each worktree gets its own URL, cookies, and sessions:

```bash
# Main worktree (no prefix)
rb-portless run bin/dev   # -> https://myapp.localhost

# Linked worktree on branch "fix-ui"
rb-portless run bin/dev   # -> https://fix-ui.myapp.localhost
```

Only the last `/` segment of the branch is used by default. In `portless.json`, set
`worktree.prefix` to `"branch"` for the full branch, or `worktree.hostnameTemplate` to
build the hostname from `{worktree}` (required) and `{name}` (optional), e.g.
`tenant.{worktree}-{name}`. Use `--prefix <label>` or `PORTLESS_PREFIX` to set the label
yourself (`""` for none). `rb-portless get <name> --no-worktree` prints the URL without
worktree naming.

### Bypassing rb-portless

Set `PORTLESS=0` to run the command directly, without the proxy:

```bash
PORTLESS=0 rb-portless run bin/dev   # plain bin/dev on its default port
```

When a proxied command is stopped with Ctrl+C, rb-portless waits for its process tree to
exit. A second Ctrl+C forwards another interrupt, and remaining descendants are
terminated after a short grace period.

## How It Works

1. `rb-portless proxy start` starts an HTTPS reverse proxy (HTTP/2) on port 443 as a
   background daemon, asking for sudo on macOS/Linux when the port needs it. Use
   `--no-tls` for plain HTTP on port 80, `-p` / `--port` or `PORTLESS_PORT` for another
   port. The proxy also auto-starts when you run an app.
2. `rb-portless <name> <cmd>` assigns a free port (4000-4999) via `PORT` and registers the
   route in `~/.rb-portless/routes.json`.
3. The browser hits `https://<name>.localhost`; the proxy forwards to the app's port.

Outside LAN mode, the proxy binds only to `127.0.0.1` and `::1`.

With `--unprivileged` (or `PORTLESS_UNPRIVILEGED=1`) the proxy takes a port below 1024
without `sudo`: it binds the wildcard addresses, which macOS allows for non-root
processes, and refuses every non-loopback peer itself. It serves plain HTTP on port 80
unless `--https` is given; with `--https` the CA is generated but not installed, so run
`rb-portless trust` once yourself. It never writes `/etc/hosts`. Linux needs
`net.ipv4.ip_unprivileged_port_start` to cover the port; rb-portless prints the sysctl
command instead of falling back to another port. This mode never prompts, so it suits
scripts, agents, and managed machines.

When rb-portless itself returns an error (404 unknown host, 421 misdirected request, 502
app unreachable, 508 request loop), browsers (`Accept: text/html`) get an HTML page and
other clients get JSON such as
`{"error":"bad_gateway","upstream":"myapp.localhost","message":"..."}`. Parse that JSON
instead of scraping HTML. Responses from the app itself are forwarded unchanged.

`.localhost` resolves to `127.0.0.1` natively in Chrome, Firefox, and Edge. Safari uses
the system resolver; rb-portless keeps `/etc/hosts` in sync for route hostnames
(`PORTLESS_SYNC_HOSTS=0` disables it, `rb-portless hosts sync` runs it by hand). If a
route hostname will not resolve, the command that registered it warns and points you to
`rb-portless hosts sync`.

`--tld` picks other TLDs, repeated or comma separated (`--tld localhost --tld test`);
`PORTLESS_URL` uses the first. TLDs can be multi-segment (`dev.example.com`), which strict
OAuth providers accept (see the `rb-portless-oauth` skill).

`rb-portless alias <name> <port>` registers a static route for something rb-portless
didn't start (a Docker container, a server you run yourself). `--upstream https` uses TLS
to the loopback backend while preserving Host; `--upstream https://api.internal[:port]`
also overrides Host and SNI. `rb-portless compose up` gives each Docker Compose service a
route.

If a wrapped command daemonizes itself (exits while its server keeps listening on the
assigned port, e.g. `puma -d` on older Puma), rb-portless keeps the route pointed at
that server and prints its PID. The route goes away when the server stops.

### Ruby clients and the local CA

rb-portless sets `SSL_CERT_FILE` in the child to a bundle of the system roots plus the
rb-portless CA (and `NODE_EXTRA_CA_CERTS` for Node), so `Net::HTTP`, Faraday, HTTParty,
and other OpenSSL-based clients trust sibling `https://*.localhost` apps without
`verify_mode = VERIFY_NONE`, while public HTTPS keeps working. An `SSL_CERT_FILE` you
already set wins. For a Ruby process started outside rb-portless:

```bash
SSL_CERT_FILE=~/.rb-portless/ca-bundle.pem bin/rails console
```

The bundle is written the first time an app runs with TLS on. Alternatively, use
`--no-tls` for plain HTTP.

### State directory

State (routes, PID file, port file, CA) lives in `~/.rb-portless`. When the proxy runs
under sudo, this stays the invoking user's home directory. Override with
`PORTLESS_STATE_DIR`.

### Environment variables

| Variable                | Description                                                                    |
| ----------------------- | ------------------------------------------------------------------------------ |
| `PORTLESS_PORT`         | Override the default proxy port (default: 443 with HTTPS, 80 without)          |
| `PORTLESS_APP_PORT`     | Use a fixed port for the app; several proxied apps need per-app `appPort`      |
| `PORTLESS_PREFIX`       | Set the worktree prefix (`""` for none, same as `--prefix`)                    |
| `PORTLESS_HTTPS`        | HTTPS on by default; set to `0` to disable (same as `--no-tls`)                |
| `PORTLESS_LAN`          | Set to `1` to always enable LAN mode (auto-detects LAN IP)                     |
| `PORTLESS_LAN_IP`       | Pin a specific LAN IP for LAN mode                                             |
| `PORTLESS_TLD`          | Use one or more TLDs, single or multi-segment (e.g. localhost,dev.example.com) |
| `PORTLESS_WILDCARD`     | Set to `1` to allow unregistered subdomains to fall back to parent             |
| `PORTLESS_UNPRIVILEGED` | Set to `1` to take a port below 1024 without sudo (same as `--unprivileged`)   |
| `PORTLESS_SYNC_HOSTS`   | Set to `0` to disable auto-sync of /etc/hosts (on by default)                  |
| `PORTLESS_TAILSCALE`    | Set to `1` to share apps on your Tailscale network (same as `--tailscale`)     |
| `PORTLESS_FUNNEL`       | Set to `1` to share apps publicly via Tailscale Funnel (same as `--funnel`)    |
| `PORTLESS_NGROK`        | Set to `1` to share apps publicly via ngrok (same as `--ngrok`)                |
| `PORTLESS_CLOUDFLARE`   | Set to `1` to share apps publicly via Cloudflare (same as `--cloudflare`)      |
| `PORTLESS_STATE_DIR`    | Override the state directory                                                   |
| `PORTLESS=0`            | Bypass the proxy, run the command directly                                     |

The child also receives `PORT`, `HOST=127.0.0.1`, `PORTLESS_URL`, and, when sharing,
`PORTLESS_TAILSCALE_URL` / `PORTLESS_NGROK_URL` / `PORTLESS_CLOUDFLARE_URL`.
rb-portless writes its status lines to stderr, so stdout carries only your app's output.
A non-empty `NO_COLOR` disables color; `FORCE_COLOR=0`/`1` disables or forces it.

### HTTPS

HTTPS with HTTP/2 is on by default. WebSockets work over HTTP/1.1 and HTTP/2, so Action
Cable, Turbo Streams, and dev-server live reload work through the proxy. The first run
generates a local CA and adds it to the system trust store (macOS keychain, or
`update-ca-certificates` / `update-ca-trust` on Linux). After that, no prompts and no
browser warnings.

```bash
rb-portless proxy start --cert ./c.pem --key ./k.pem  # Use custom certs
rb-portless proxy start --no-tls                       # Disable HTTPS (plain HTTP)
rb-portless trust                                      # Add CA to trust store later
```

### LAN mode

```bash
rb-portless proxy start --lan
rb-portless proxy start --lan --ip 192.168.1.42
```

`--lan` binds the proxy to `0.0.0.0` and `::` and advertises `<name>.local` hostnames
over mDNS so phones on the same Wi-Fi can reach **every** running app. rb-portless
follows LAN IP changes; pin one with `--ip` or `PORTLESS_LAN_IP`. `PORTLESS_LAN=1`
makes LAN mode the default; `PORTLESS_LAN=0` switches back for one start. macOS ships
`dns-sd`; Linux needs `avahi-publish-address` (`sudo apt install avahi-utils`).

Rails: add `config.hosts << ".local"`.

### Sharing (Tailscale, ngrok, Cloudflare)

```bash
rb-portless myapp --tailscale bin/dev    # tailnet: https://devbox.yourteam.ts.net
rb-portless myapp --funnel bin/dev       # public via Tailscale Funnel
rb-portless myapp --ngrok bin/dev        # public: https://abc123.ngrok.app
rb-portless myapp --cloudflare bin/dev   # public: https://<random>.trycloudflare.com
```

- `--tailscale` / `--funnel` need the `tailscale` CLI connected, with Tailscale HTTPS
  certificates enabled (and Funnel enabled for `--funnel`). Each app gets its own
  Tailscale HTTPS port (443, then 8443, 8444, ...), so no path prefix is needed.
- `--ngrok` needs the `ngrok` CLI, authenticated with `ngrok config add-authtoken <token>`.
- `--cloudflare` opens a quick tunnel with `cloudflared`, no account needed. Quick
  tunnels don't support Server-Sent Events, allow at most 200 in-flight requests, and get
  a new URL every run.

`rb-portless list` shows the shared URLs; tunnels and serve registrations are cleaned up
when the app exits. Rails blocks the shared hostname until you allow it, e.g.
`config.hosts << ".ts.net"`, `".ngrok.app"`, or `".trycloudflare.com"`.

## OS startup service

```bash
rb-portless service install
rb-portless service install --lan
rb-portless service install --wildcard
rb-portless service status
rb-portless service uninstall
```

`service install` accepts the proxy options (`--port`, `--no-tls`, `--lan`, `--ip`,
`--tld`, `--wildcard`, `--cert`, `--key`, `--state-dir`) and writes them into a
root-owned launchd (`rb.portless.proxy`) or systemd (`rb-portless.service`) unit so port
443 binds at boot. `rb-portless clean` removes the service.

## CLI Reference

Exit codes: `0` success, `1` failure, `2` usage error (unknown flag or subcommand,
missing value or argument, extra argument, or a command that needs `--yes` without a
terminal). Wrapped commands keep their own exit code. Value flags accept `--flag value`
or `--flag=value`.

| Command                                              | Description                                                    |
| ---------------------------------------------------- | -------------------------------------------------------------- |
| `rb-portless run <cmd> [args...]`                    | Infer name from project, run through proxy (auto-starts)       |
| `rb-portless run --name <name> <cmd>`                | Override inferred base name (worktree prefix still applies)    |
| `rb-portless run --prefix <label> <cmd>`             | Set the worktree prefix (`""` for none)                        |
| `rb-portless <name> <cmd> [args...]`                 | Run app at `https://<name>.localhost` (auto-starts proxy)      |
| `rb-portless`                                        | Run the package.json dev script (or all workspace packages)    |
| `rb-portless --script <name>`                        | Run a specific package.json script (default: dev)              |
| `rb-portless get <name>`                             | Print URL for a service (for cross-service wiring)             |
| `rb-portless get <name> --json`                      | Print name, hostname, and URL as JSON                          |
| `rb-portless list` / `list --json`                   | Show active routes and uptime                                  |
| `rb-portless doctor` / `doctor --json`               | Check Ruby, proxy, routes, DNS, CA trust, and LAN prerequisites |
| `rb-portless trust`                                  | Add local CA to system trust store                             |
| `rb-portless clean`                                  | Remove state, CA trust entry, service, and /etc/hosts block    |
| `rb-portless prune` / `prune --force`                | Remove stale routes and shares; stop leftover process groups   |
| `rb-portless proxy start`                            | Start HTTPS proxy as a daemon (port 443, asks for sudo)        |
| `rb-portless proxy start --no-tls`                   | Plain HTTP on port 80                                          |
| `rb-portless proxy start --unprivileged`             | Plain HTTP on port 80 without sudo, nothing installed          |
| `rb-portless proxy start -p <number>`                | Start the proxy on a custom port                               |
| `rb-portless proxy start --lan`                      | LAN mode (mDNS `.local`)                                       |
| `rb-portless proxy start --tld test`                 | Use .test instead of .localhost                                |
| `rb-portless proxy start --wildcard`                 | Allow unregistered subdomains to fall back to parent route     |
| `rb-portless proxy start --foreground`               | Run the proxy in the foreground (for debugging)                |
| `rb-portless proxy stop`                             | Stop the proxy                                                 |
| `rb-portless service install` / `status` / `uninstall` | Manage the startup service                                   |
| `rb-portless alias <name> <port>`                    | Register a static route (e.g. a Docker container)              |
| `rb-portless alias <name> <port> --force`            | Stop the conflicting app and overwrite its route               |
| `rb-portless alias --remove <name>`                  | Remove static (PID 0) routes                                   |
| `rb-portless compose up` / `down [args...]`          | Docker Compose with a route per service                        |
| `rb-portless hosts sync` / `hosts clean`             | Reconcile or remove the /etc/hosts block                       |
| `rb-portless <name> --app-port <n> <cmd>`            | Use a fixed port for the app                                   |
| `rb-portless <name> --force <cmd>`                   | Kill the existing process and take over its route              |
| `rb-portless --name <name> <cmd>`                    | Force `<name>` as app name (bypasses subcommand dispatch)      |
| `rb-portless <name> -- <cmd> [args...]`              | Stop flag parsing; everything after `--` goes to the child     |
| `rb-portless mcp [--tools <profiles>]`               | Start the MCP server over stdio                                |
| `rb-portless <command> --help`                       | Print command help without running it                          |
| `rb-portless --version`                              | Show version                                                   |

After `run <cmd>`, `compose <subcommand>`, or `--`, `--help` belongs to the wrapped
command, so `rb-portless run bin/rails server --help` prints Rails' help.

**Reserved names:** `run`, `get`, `alias`, `compose`, `hosts`, `list`, `doctor`, `trust`,
`clean`, `prune`, `proxy`, `service`, and `mcp` cannot be used as app names directly. Use
`rb-portless run <cmd>` or `rb-portless --name <name> <cmd>`.

## MCP server

`rb-portless mcp` starts a stdio MCP server. The default `core` profile lists routes,
looks up URLs, and manages static aliases; add `proxy`, `diagnostics`, or `all` with
`--tools`. It does not run dev servers; start them with `rb-portless run <cmd>` in a shell.

```json
{ "mcpServers": { "rb-portless": { "command": "rb-portless", "args": ["mcp"] } } }
```

## portless.json

Optional config file, looked up in the current directory (same schema as upstream).

| Field      | Type    | Default       | Description                                                       |
| ---------- | ------- | ------------- | ----------------------------------------------------------------- |
| `name`     | string  | inferred      | Base app name (worktree prefix still applies)                     |
| `script`   | string  | `"dev"`       | package.json script to run in bare mode                           |
| `appPort`  | number  | auto-assigned | Fixed port for the child process                                  |
| `proxy`    | boolean | auto-detected | Whether to route through the proxy (`false` for non-server tasks) |
| `apps`     | object  |               | Overrides for workspace packages, keyed by relative path          |
| `worktree` | object  |               | Worktree label style and hostname template                        |
| `turbo`    | boolean | `true`        | Set `false` to spawn directly instead of through Turborepo        |

A `"portless"` key in `package.json` works too (`{ "portless": "myapp" }` or an object
with the per-app fields) when the directory has no `portless.json`. Precedence: CLI
flags override `PORTLESS_*` variables, which override the config file.

## Troubleshooting

### Run diagnostics

Run `rb-portless doctor` first. It is read-only and checks the Ruby version, state
directory permissions, proxy liveness, routes, hostname resolution, local CA trust, and
LAN prerequisites. `--json` prints the report as JSON.

For 502 errors, stop the proxy with `rb-portless proxy stop`, then run
`rb-portless proxy start --foreground` to see each failed loopback connection.

### 502 Bad Gateway from a Rails app

The app isn't listening on the port rb-portless assigned. Check the `Running: PORT=...`
line, then:

- No `-p 3000` / `--port 3000` in the command, `Procfile.dev`, or `.foreman`.
- No `PORT=3000` in `.env` (foreman loads it over the assigned port).
- With `bin/dev`, `web:` must be the first `Procfile.dev` entry (see above).
- Running `puma` directly (not `bin/rails server`): `config/puma.rb` must use
  `ENV.fetch("PORT", ...)`; a hardcoded `port 3000` makes Puma listen there instead.
  `bin/rails server` passes `PORT` to Puma itself and overrides the config file.
- A second server in the same checkout exited on `tmp/pids/server.pid` (see above).

### Blocked hosts / 403 from Rails

Allow the host in `config.hosts` (see Allowed hosts above). Multi-label names such as
`api.myapp.localhost` need `.myapp.localhost` even on `.localhost`. `rb-portless list`
shows which hostnames the proxy serves.

### Proxy not running

The proxy auto-starts when you run an app. If it doesn't (e.g. port conflict), start it
yourself: `rb-portless proxy start`.

### Port already in use / permission errors

Ports 80 and 443 need `sudo` on macOS and Linux; rb-portless asks for it. Without a TTY
or sudo it exits and prints the commands to run instead:

```bash
rb-portless proxy start               # asks for sudo for port 443
rb-portless proxy start -p 1355       # no sudo (URLs include :1355)
rb-portless proxy start --unprivileged  # plain HTTP on 80, no sudo, clean URLs
rb-portless proxy stop
```

### Safari can't find .localhost URLs

```bash
rb-portless hosts sync    # reconcile routes with /etc/hosts
rb-portless hosts clean   # remove entries later
```

### Browser shows a certificate warning

Run `rb-portless trust`, then restart the browser.

On macOS and Linux, `trust`, `proxy stop`, `prune`, `hosts sync`, `service install`, and
`clean` act on a state directory only when no other user can change it (owned by you or
root, not group/other writable, all the way up). Fix with `chmod go-w <dir>` or point
`PORTLESS_STATE_DIR` elsewhere.

### `OpenSSL::SSL::SSLError` calling another local app

A Ruby process started outside rb-portless doesn't trust the local CA. Use
`SSL_CERT_FILE=~/.rb-portless/ca-bundle.pem` (see above), or run it through rb-portless.

### Proxy loop (508 Loop Detected)

If your app proxies requests to another rb-portless app (e.g. Vite proxying `/api` to
`api.myapp.localhost`, or a Rack proxy), the proxy must rewrite the `Host` header to the
target. Otherwise rb-portless routes the request back to the original app. For Vite:

```ts
proxy: { "/api": { target: "https://api.myapp.localhost", changeOrigin: true, ws: true } }
```

### Remove rb-portless from the machine

```bash
rb-portless clean      # previews, then asks; --yes / -y without a terminal
gem uninstall rb-portless
```

Stops the proxy, removes the startup service, the rb-portless CA from the trust store
(when rb-portless added it), known state files, and the `/etc/hosts` block.

### Requirements

- Ruby 3.2+
- macOS or Linux (Windows is not supported)
- `tailscale`, `ngrok`, or `cloudflared` CLI (optional, for sharing)
- Docker Compose (optional, for `compose`)
