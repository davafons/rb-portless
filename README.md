<h1 align="center">rb-portless</h1>

<p align="center">
  <a href="https://rubygems.org/gems/rb-portless"><img src="https://img.shields.io/gem/v/rb-portless" alt="Gem Version"></a>
  <a href="https://github.com/davafons/rb-portless/actions/workflows/ci.yml"><img src="https://github.com/davafons/rb-portless/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/davafons/rb-portless/blob/main/LICENSE"><img src="https://img.shields.io/github/license/davafons/rb-portless" alt="License"></a>
  <a href="https://rubygems.org/gems/rb-portless"><img src="https://img.shields.io/gem/dt/rb-portless" alt="Downloads"></a>
</p>

<p align="center">
  Stable, named <code>.localhost</code> URLs for local development —<br>
  a native-Ruby port of <a href="https://github.com/vercel-labs/portless">Vercel's portless</a>.
</p>

```diff
- bin/rails server                     # http://localhost:3000
+ rb-portless run bin/rails server     # https://myapp.localhost
```

Run your dev server through a tiny local reverse proxy and reach it at
`https://<name>.localhost` instead of juggling ports. HTTPS by default (a local
CA + per-host certs), a random backend port so you never collide on 3000/3001,
and wildcard subdomains (`*.myapp.localhost`) so multi-tenant apps Just Work.

## Install

```bash
gem install rb-portless
```

- Ruby >= 3.2. macOS or Linux. (Windows: HTTP works; CA trust + boot service are
  on the roadmap.)

## Use

```bash
rb-portless run bin/dev            # -> https://<project>.localhost
rb-portless run bin/rails server   # anything that respects $PORT
rb-portless run -- npm run dev     # Vite/Astro/etc. get --port injected
```

A random port (4000–4999) is injected as `PORT` (and `HOST=127.0.0.1`);
Rails/puma respect it natively. The proxy **auto-starts** on first run: it
generates a local CA, **trusts it** (one keychain/sudo prompt, like portless),
and binds 443 — another one-time `sudo` on macOS/Linux (falls back to `:1355` if
you decline). After that, HTTPS just works with no browser warnings.

```bash
rb-portless trust                  # re-trust manually if ever needed
rb-portless service install        # bind 443 at boot — never prompt for sudo again
```

### Config (`portless.json`)

```json
{ "name": "shirabe", "tld": "shirabe.org.localhost" }
```

| Key       | Default     | Meaning |
| --------- | ----------- | ------- |
| `name`    | dir/git root | the subdomain label |
| `tld`     | `localhost` | base host; a multi-label value like `shirabe.org.localhost` gives every `*.shirabe.org.localhost` subdomain, all routed to the one app |
| `tls`     | `true`      | HTTPS (`false` = plain HTTP on :80) |
| `appPort` | random      | pin the backend port |

With a custom `tld`, every `*.shirabe.org.localhost` subdomain wildcard-routes to
the one app — ideal for subdomain-per-tenant apps.

## Multiple apps, LAN & sharing

**Monorepo / multi-app** — define an `apps` map and `rb-portless run` (no command)
starts them all, each at its own name:

```jsonc
// portless.json
{ "apps": { "web": "bin/rails server", "api": "node api/server.js" } }
// → https://web.localhost, https://api.localhost
```

**LAN mode** — reach the app from your phone on the same Wi-Fi. It detects the
LAN IP, registers `<name>.local`, and publishes it over mDNS:

```bash
rb-portless run --lan bin/dev      # also → https://<name>.local
rb-portless run --lan --ip 10.0.0.5 bin/dev   # override the detected IP
```
> Devices won't trust your local CA without installing it — use `--lan` with
> `--no-tls` (set `"tls": false`) for plain HTTP, or install `~/.rb-portless/ca.pem`
> on the device.

**Public sharing** (experimental) — expose the app via ngrok or your tailnet:

```bash
rb-portless run --ngrok bin/dev        # https://xxxx.ngrok.app
rb-portless run --tailscale bin/dev    # your-machine.tailnet.ts.net
rb-portless run --funnel bin/dev       # tailscale Funnel (public)
```
Each degrades gracefully if the tool isn't installed.

## Commands

| Command | Does |
| --- | --- |
| `run <cmd>` | run a dev server through the proxy |
| `proxy start \| stop` | manage the proxy daemon |
| `trust` | install the local CA into the OS trust store |
| `service install \| uninstall \| status` | bind the privileged port at boot (launchd/systemd) |
| `alias <name> <port>` | a static route (Docker, Postgres, …) |
| `get <name>` | print a name's URL (for `$(rb-portless get api)`) |
| `list` | show active routes |
| `hosts sync \| clean` | manage `/etc/hosts` (Safari / non-`.localhost` TLDs) |
| `doctor` | diagnose setup |
| `prune` | reap stale routes |
| `clean` | stop the proxy, untrust the CA, remove all state |

## Rails

Rails is first-class: it respects `PORT` and trusts the loopback proxy, so
`X-Forwarded-Host/Proto/Port` flow through and `request.host`, subdomains, and
generated URLs all reflect `https://<name>.localhost`.

**Zero-config setup.** Add the gem to your dev group with the railtie required —
that's the only project change:

```ruby
# Gemfile
group :development do
  gem "rb-portless", require: "portless/rails"
end
```

```jsonc
// portless.json  (optional — name defaults to the dir/git root)
{ "name": "myapp", "tld": "myapp.localhost" }
```

```bash
rb-portless run bin/dev      # → https://myapp.localhost (CA auto-trusted on first run)
```

That's it. The railtie **auto-detects when you're running under `rb-portless`**
(via the `PORTLESS_URL` env the runner injects) and only then whitelists your
`*.localhost` hosts in development — so Action Dispatch host authorization doesn't
`403` your named subdomains. Run `bin/dev` normally and nothing is touched.

> **`bin/dev` note:** `rb-portless run bin/dev` wraps Foreman. Foreman passes the
> injected `PORT` to the **first** process in `Procfile.dev` — keep `web:` first
> (the Rails default) so the server binds the port the proxy registered.

Prefer not to add the gem? Skip the railtie and allow the host yourself:

```ruby
# config/environments/development.rb
config.hosts << /.+\.localhost/
```

## Use cases

**Kill the port.** Stop memorizing `:3000` / `:3001`. One stable HTTPS URL per
app, the same every day:

```bash
rb-portless run bin/dev      # https://myapp.localhost
```

**Subdomain-per-tenant apps** (the headline). A multi-label `tld` gives every
subdomain to one app, so multi-tenant / Classroom-style routing works locally
exactly like production:

```jsonc
{ "name": "myapp", "tld": "myapp.localhost" }
// kobe.myapp.localhost, osaka.myapp.localhost, admin.myapp.localhost → your app
```

**Several services at once.** Give each its own name; route non-portless
processes (a database, a container) with a static `alias`:

```bash
rb-portless run bin/dev                 # https://web.localhost
rb-portless run -- node api/server.js   # https://api.localhost   (in another tab)
rb-portless alias pg 5432               # https://pg.localhost     (static)
```

**HTTPS that matches prod.** Develop against real TLS + HTTP/2, so secure-cookie
and `X-Forwarded-Proto` behaviour is the same locally as in production.

## How it works

No daemon protocol — coordination is a state dir (`~/.rb-portless`) with a
`routes.json` registry (host → backend port). The proxy resolves each request's
host to a backend and forwards it, minting a per-host TLS leaf cert on the SNI
callback (because `*.localhost` wildcard certs aren't valid at the reserved-TLD
boundary). For ports < 1024 it re-execs under `sudo` so the elevated process can
bind the socket, then hands ownership of state files back to you. See
[`AGENTS.md`](AGENTS.md) for the full architecture.

## Compared to portless (Node)

The mental model is identical — `run` wraps your dev command, the proxy
auto-starts, named `.localhost` URLs replace ports. The only Ruby-world addition
is the one-line `require "portless/rails"` to satisfy Rails' host authorization.

| | **portless (Node)** | **rb-portless (Ruby/Rails)** |
|---|---|---|
| Install | `npm i -g portless` | `gem install rb-portless` (or Gemfile dev group) |
| Run a server | `portless run next dev` | `rb-portless run bin/rails server` |
| Run the dev orchestrator | `portless` (runs `"dev"` script) | `rb-portless run bin/dev` (wraps Foreman) |
| Bake into the project | `"dev": "portless run next dev"` → `npm run dev` | put `rb-portless run` in `bin/dev`, or use the binstub |
| Name the URL | `portless myapp …` / `portless.json` | `portless.json` `{ "name": "myapp" }` (else dir/git root) |
| Wildcard tenant subdomains | `tld` config | `portless.json` `{ "tld": "myapp.localhost" }` → `*.myapp.localhost` |
| Pin the backend port | `--app-port` / `appPort` | `appPort` in `portless.json` |
| Framework port injection | vite/astro/etc. auto | same (Rails/puma respect `PORT` natively) |
| HTTPS trust | auto on first run (+ `portless trust`) | auto on first run (+ `rb-portless trust`) |
| **Host allowlist** | not needed | **`gem "rb-portless", require: "portless/rails"`** (Rails-only) |
| Privileged 443 bind | sudo re-exec (auto) | sudo re-exec (auto), `:1355` fallback |
| Bind at boot (no sudo) | `portless service install` | `rb-portless service install` |
| Inspect / manage | `portless list / doctor / clean` | `rb-portless list / doctor / clean` |
| Static route (DB, etc.) | `portless alias pg 5432` | `rb-portless alias pg 5432` |

## Contributing

```bash
bundle install
bundle exec rake test
bundle exec rubocop
```

## License

MIT.
