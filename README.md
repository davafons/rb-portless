<h1 align="center">portless-rb</h1>

<p align="center">
  <a href="https://rubygems.org/gems/portless-rb"><img src="https://img.shields.io/gem/v/portless-rb" alt="Gem Version"></a>
  <a href="https://github.com/davafons/portless-rb/actions/workflows/ci.yml"><img src="https://github.com/davafons/portless-rb/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/davafons/portless-rb/blob/main/LICENSE"><img src="https://img.shields.io/github/license/davafons/portless-rb" alt="License"></a>
  <a href="https://rubygems.org/gems/portless-rb"><img src="https://img.shields.io/gem/dt/portless-rb" alt="Downloads"></a>
</p>

<p align="center">
  Stable, named <code>.localhost</code> URLs for local development —<br>
  a native-Ruby port of <a href="https://github.com/vercel-labs/portless">Vercel's portless</a>.
</p>

```diff
- bin/rails server                     # http://localhost:3000
+ portless-rb run bin/rails server     # https://myapp.localhost
```

Run your dev server through a tiny local reverse proxy and reach it at
`https://<name>.localhost` instead of juggling ports. HTTPS by default (a local
CA + per-host certs), a random backend port so you never collide on 3000/3001,
and wildcard subdomains (`*.myapp.localhost`) so multi-tenant apps Just Work.

## Install

```bash
gem install portless-rb
```

- Ruby >= 3.2. macOS or Linux. (Windows: HTTP works; CA trust + boot service are
  on the roadmap.)

## Use

```bash
portless-rb run bin/dev            # -> https://<project>.localhost
portless-rb run bin/rails server   # anything that respects $PORT
portless-rb run -- npm run dev     # Vite/Astro/etc. get --port injected
```

A random port (4000–4999) is injected as `PORT` (and `HOST=127.0.0.1`);
Rails/puma respect it natively. The proxy **auto-starts** on first run: it
generates a local CA, and binds 443 — a one-time `sudo` on macOS/Linux, exactly
like portless (falls back to `:1355` if you decline). Run `portless-rb trust`
once so your browser accepts the certificates.

```bash
portless-rb trust                  # trust the local CA (HTTPS, no warnings)
portless-rb service install        # bind 443 at boot — never prompt for sudo again
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

## Commands

| Command | Does |
| --- | --- |
| `run <cmd>` | run a dev server through the proxy |
| `proxy start \| stop` | manage the proxy daemon |
| `trust` | install the local CA into the OS trust store |
| `service install \| uninstall \| status` | bind the privileged port at boot (launchd/systemd) |
| `alias <name> <port>` | a static route (Docker, Postgres, …) |
| `get <name>` | print a name's URL (for `$(portless-rb get api)`) |
| `list` | show active routes |
| `hosts sync \| clean` | manage `/etc/hosts` (Safari / non-`.localhost` TLDs) |
| `doctor` | diagnose setup |
| `prune` | reap stale routes |
| `clean` | stop the proxy, untrust the CA, remove all state |

## Rails

Rails is first-class: it respects `PORT` and trusts the loopback proxy, so
`X-Forwarded-Host/Proto/Port` flow through and `request.host`, subdomains, and
generated URLs all reflect `https://<name>.localhost`. Subdomain-per-tenant apps
work out of the box via the wildcard `tld`.

```bash
echo '{ "name": "myapp", "tld": "myapp.localhost" }' > portless.json
portless-rb run bin/rails server
# tenant.myapp.localhost, admin.myapp.localhost, … all reach your app
```

## How it works

No daemon protocol — coordination is a state dir (`~/.portless-rb`) with a
`routes.json` registry (host → backend port). The proxy resolves each request's
host to a backend and forwards it, minting a per-host TLS leaf cert on the SNI
callback (because `*.localhost` wildcard certs aren't valid at the reserved-TLD
boundary). For ports < 1024 it re-execs under `sudo` so the elevated process can
bind the socket, then hands ownership of state files back to you. See
[`AGENTS.md`](AGENTS.md) for the full architecture.

## Contributing

```bash
bundle install
bundle exec rake test
bundle exec rubocop
```

## License

MIT.
