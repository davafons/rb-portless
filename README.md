<h1 align="center">rb-portless</h1>

<p align="center">
  <a href="https://rubygems.org/gems/rb-portless"><img src="https://img.shields.io/gem/v/rb-portless" alt="Gem Version"></a>
  <a href="https://github.com/davafons/rb-portless/actions/workflows/ci.yml"><img src="https://github.com/davafons/rb-portless/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/davafons/rb-portless/blob/main/LICENSE"><img src="https://img.shields.io/github/license/davafons/rb-portless" alt="License"></a>
</p>

<p align="center">
  Replace port numbers with stable, named <code>.localhost</code> URLs for local development.<br>
  A native-Ruby port of <a href="https://github.com/vercel-labs/portless">Vercel's portless</a>, kept at feature parity.
</p>

```diff
- bin/rails server                     # http://localhost:3000
+ rb-portless run bin/rails server     # https://myapp.localhost
```

rb-portless runs a local reverse proxy and gives each dev server a name. Your app
listens on a free port that rb-portless assigns, and you open `https://<name>.localhost`
instead of remembering which port it took. The URL stays the same across restarts, so
bookmarks, cookies, OAuth redirects, and an agent's test script keep pointing at the
right app.

rb-portless behaves like upstream portless: same commands, flags, environment variables,
`portless.json` and `package.json` configuration, routing, and output. The
[portless.sh](https://portless.sh) documentation applies — read `portless` as
`rb-portless` in commands. The only differences are names, so both tools can be
installed side by side:

| | portless | rb-portless |
| --- | --- | --- |
| Executable | `portless` | `rb-portless` |
| State directory | `~/.portless` | `~/.rb-portless` (`PORTLESS_STATE_DIR` overrides) |
| `/etc/hosts` block | `# portless-start` | `# rb-portless-start` |
| Boot service | `sh.portless.proxy` | `rb.portless.proxy` / `rb-portless.service` |
| Child CA env | `NODE_EXTRA_CA_CERTS` | also `SSL_CERT_FILE` (a bundle of system roots + the local CA), so Ruby clients trust `.localhost` HTTPS |

## Install

```bash
gem install rb-portless
```

Ruby 3.3 or later, on macOS or Linux.

## Quick start

```bash
rb-portless myapp bin/rails server
# -> https://myapp.localhost

rb-portless run bin/dev
# -> https://<project>.localhost
```

From a project with a `"dev"` script in `package.json`, a bare `rb-portless` runs that
script through the detected package manager. Pass arguments to the script after `--`.

The name comes from `package.json`, the git root, or the directory.

- The proxy starts on the first run. It serves HTTPS with HTTP/2 on port 443, so the
  first run creates a local certificate authority, adds it to the system trust store, and
  may ask for `sudo`. Use `--no-tls` for plain HTTP, or `--unprivileged` to skip `sudo`.
- `rb-portless run <cmd>` infers the name and detects git worktrees. In a linked worktree,
  the last `/` segment of the branch becomes a subdomain, so `fix-ui.myapp.localhost` and
  `myapp.localhost` run side by side. Use `--prefix` or `PORTLESS_PREFIX` to set the
  label, or the `worktree` setting in `portless.json`.
- A name with dots is a subdomain: `rb-portless api.myapp bin/rails server` serves
  `https://api.myapp.localhost`.
- `PORTLESS=0 bin/dev` runs the command directly, without the proxy.

## How it works

Each app gets a random port from 4000 to 4999 through the `PORT` environment variable
(Rails and Puma read it), and registers a route from its hostname to that port in
`routes.json`. The proxy forwards `https://<name>.localhost` to the route. For frameworks
that ignore `PORT`, such as Vite, Astro, Angular, Expo, and Wrangler, rb-portless adds the
matching port and host flags to the command.

Routing is exact by default: an unregistered subdomain gets a 404. Start the proxy with
`--wildcard` (or `PORTLESS_WILDCARD=1`) to send `tenant.myapp.localhost` to the most
specific registered parent, `myapp.localhost`.

Outside LAN mode, the proxy listens only on `127.0.0.1` and `::1`. It keeps `/etc/hosts`
in sync for route hostnames, which custom TLDs such as `.test` need. If a route hostname
will not resolve, the command that registered it warns and points you to
`rb-portless hosts sync`.

To reach an app from another device or share it, use LAN mode (`--lan`) for phones on the
same network — every running app is then reachable on that network, published over mDNS
as `<name>.local` — or share one app with `--tailscale`, `--funnel`, `--ngrok`, or
`--cloudflare`.

## Configuration

An optional `portless.json` sets the name and script. In a monorepo, one file at the root
covers every workspace package:

```json
{
  "apps": {
    "apps/web": { "name": "myapp" },
    "apps/api": { "name": "api.myapp" }
  }
}
```

A `"portless"` key in `package.json` works too. Flags override `PORTLESS_*` variables,
which override `portless.json`. See [Configuration](https://portless.sh/configuration).

## For AI agents

Install the rb-portless skills (Ruby/Rails versions of upstream's portless and OAuth
skills) into an agent harness:

```bash
npx skills add davafons/rb-portless
```

`rb-portless mcp` starts an MCP server over stdio. The default `core` profile lists
routes, looks up URLs, and manages static aliases. `--tools all` adds proxy control and
diagnostics:

```json
{ "mcpServers": { "rb-portless": { "command": "rb-portless", "args": ["mcp"] } } }
```

## Commands

Run `rb-portless --help` for the command list, `rb-portless proxy --help` for proxy
options, or `rb-portless <command> --help` for details. Usage errors exit with code `2`;
other failures exit with `1`. Use `rb-portless list --json` or `rb-portless get <name> --json`
for JSON output.

| Group | Commands |
| --- | --- |
| Run apps | `rb-portless`, `run`, `<name> <cmd>`, `get` |
| Static routes | `alias`, `compose up`, `compose down` |
| Proxy | `proxy start`, `proxy stop`, `service install`, `service status`, `service uninstall` |
| HTTPS and DNS | `trust`, `hosts sync`, `hosts clean` |
| Inspect and clean up | `list`, `doctor`, `prune`, `clean` |
| Agents | `mcp` |

## Platforms

macOS and Linux. Windows CA trust and the Windows boot service are not ported.
`--tailscale` and `--funnel` need the Tailscale CLI, `--ngrok` needs the ngrok CLI,
`--cloudflare` needs `cloudflared`, and `compose` needs Docker Compose.

## Development

```bash
bundle install
bundle exec rake test
bundle exec rubocop
```

Upstream is cloned into `references/portless` (gitignored) for diffing and differential
tests. [AGENTS.md](AGENTS.md) maps each Ruby file to its upstream source.

## License

MIT. Ports code from [vercel-labs/portless](https://github.com/vercel-labs/portless)
(Apache-2.0).
