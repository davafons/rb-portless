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
`https://<name>.localhost` instead of juggling ports. HTTPS by default (local CA
+ per-host certs), a random backend port so you never collide on 3000/3001, and
wildcard subdomains (`*.myapp.localhost`) so multi-tenant apps Just Work.

> Status: **early.** Phase 0 (scaffold + coordination layer) is in; the proxy,
> certs, and runner land next. See `AGENTS.md` for the build plan.

## Install

```bash
gem install portless-rb
```

## Use

```bash
portless-rb run bin/dev          # -> https://<project>.localhost
portless-rb run -- npm run dev    # anything that respects $PORT
```

A random port (4000–4999) is injected as `PORT`; Rails/puma respect it natively.
The proxy auto-starts; on first run it generates a local CA, trusts it, and binds
443 (one-time `sudo` on macOS/Linux, exactly like portless — falls back to
`:1355` if denied).

### Config (`portless.json`)

```json
{ "name": "shirabe", "tld": "shirabe.org.localhost" }
```

With a custom `tld`, every `*.shirabe.org.localhost` subdomain wildcard-routes to
the one app — ideal for subdomain-per-tenant apps.

## Framework-agnostic

The core is just a reverse proxy + process runner; nothing is framework-specific.
Rails is the first-class test target (it respects `PORT` and `X-Forwarded-*` out
of the box).

## License

MIT.
