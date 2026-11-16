---
name: rb-portless-oauth
description: Configure OAuth providers (Google, Apple, Microsoft, Facebook, GitHub, etc.) to work with rb-portless local dev URLs in Ruby and Rails apps (OmniAuth, Devise, Rodauth, Doorkeeper clients). Use when setting up OAuth redirect URIs, fixing "redirect_uri_mismatch" or "invalid redirect" errors, configuring sign-in providers for local development, or when a provider rejects .localhost subdomains. Triggers include "OAuth not working with rb-portless", "redirect URI mismatch", "Google/Apple/Microsoft sign-in fails locally", "OmniAuth callback goes to localhost", or any task involving OAuth callback URLs with rb-portless domains.
---

# OAuth with rb-portless

OAuth providers validate redirect URIs against domain rules. `.localhost` subdomains fail
on most providers because they are not in the Public Suffix List or are explicitly
blocked. rb-portless fixes this with `--tld`, which serves apps on real, valid domains.

## The Problem

With the default `.localhost` TLD, providers reject redirect URIs like
`https://myapp.localhost/users/auth/google_oauth2/callback`:

| Provider  | `localhost` | `.localhost` subdomains | Reason                         |
| --------- | ----------- | ----------------------- | ------------------------------ |
| Google    | Allowed     | Rejected                | Not in their bundled PSL       |
| Apple     | Rejected    | Rejected                | No localhost at all            |
| Microsoft | Allowed     | Allowed                 | Permissive localhost handling  |
| Facebook  | Allowed     | Varies                  | Must register each URI exactly |
| GitHub    | Allowed     | Allowed                 | Permissive                     |

Google and Apple are the strictest. Microsoft and GitHub are more lenient.

## The Fix

Use a valid TLD so the redirect URI passes provider validation:

```bash
rb-portless proxy start --tld dev
rb-portless myapp bin/dev
# -> https://myapp.dev
```

Any TLD in the Public Suffix List works: `.dev`, `.app`, `.com`, `.io`, etc.

Rails blocks hosts it doesn't know, so allow the TLD in
`config/environments/development.rb`:

```ruby
config.hosts << ".dev"
```

### Use a domain you own

Bare TLDs like `.dev` mean `myapp.dev` could collide with a real domain. Use a
multi-segment TLD under a domain you control, so the app name stays clean and the domain
structure lives in the TLD:

```bash
rb-portless proxy start --tld local.yourcompany.dev
rb-portless myapp bin/dev
# -> https://myapp.local.yourcompany.dev
```

```ruby
config.hosts << ".local.yourcompany.dev"
```

This ensures no outbound traffic reaches something you don't own. For teams, set a
wildcard DNS record (`*.local.yourcompany.dev -> 127.0.0.1`) so every developer gets
resolution without `/etc/hosts`, and everyone shares the same redirect URIs in the
provider console.

## Provider Setup

The paths below are OmniAuth's defaults (`/auth/:provider/callback`). With Devise's
`:omniauthable`, they live under the Devise scope, e.g. `/users/auth/:provider/callback`.
Use `bin/rails routes -g callback` to see yours.

### Google (`omniauth-google-oauth2`)

1. Go to [Google Cloud Console > Credentials](https://console.cloud.google.com/apis/credentials)
2. Create or edit an OAuth 2.0 Client ID (Web application)
3. Add the domain to **Authorized JavaScript origins**: `https://myapp.dev`
4. Add the callback to **Authorized redirect URIs**: `https://myapp.dev/auth/google_oauth2/callback`

Google validates domains against the Public Suffix List. `.localhost` subdomains fail
this check; `.dev`, `.app`, `.com`, etc. pass.

HTTPS is required for `.dev` and `.app` (HSTS-preloaded). rb-portless serves HTTPS by
default.

### Apple (`omniauth-apple`)

Apple Sign In does not allow `localhost` or IP addresses at all.

1. Go to [Apple Developer > Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources)
2. Register a Services ID
3. Configure Sign In with Apple, adding the domain as a **Return URL**: `https://myapp.dev/auth/apple/callback`

The domain must be a real, publicly resolvable name. rb-portless maps it to 127.0.0.1
locally, so the browser resolves it, but Apple's server-side validation may require
public resolution too. If Apple rejects the domain, add a public DNS A record pointing to
127.0.0.1 for your dev subdomain.

Apple posts the callback as a cross-site `form_post`, so the session cookie must be sent
on that POST. If the OmniAuth state check fails (`csrf_detected`), configure the cookie
with `same_site: :none, secure: true` in development.

### Microsoft (Entra / Azure AD, `omniauth-entra-id`)

1. Go to [Azure Portal > App registrations](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps)
2. Create or edit an app registration
3. Under **Authentication**, add a **Web** redirect URI: `https://myapp.dev/auth/entra_id/callback`

Microsoft allows `http://localhost` with any port and accepts `.localhost` subdomains in
most cases. A custom TLD is still recommended for consistency across providers.

### Facebook (Meta, `omniauth-facebook`)

1. Go to [Meta for Developers > App Dashboard](https://developers.facebook.com/apps/)
2. Under **Facebook Login > Settings**, add **Valid OAuth Redirect URIs**: `https://myapp.dev/auth/facebook/callback`

Facebook requires each redirect URI to be registered exactly (no wildcards). Strict Mode
(on by default) enforces exact matching.

### GitHub (`omniauth-github`)

1. Go to [GitHub Developer Settings > OAuth Apps](https://github.com/settings/developers)
2. Set **Authorization callback URL**: `https://myapp.dev/auth/github/callback`

GitHub is permissive with localhost and subdomains. A custom TLD is not strictly required
but keeps the setup consistent.

## Auth Library Configuration

### OmniAuth / Devise

OmniAuth builds the callback URL from the request. The proxy preserves `Host` and sets
`X-Forwarded-Proto: https`, and Rails trusts forwarded headers from loopback, so the
callback is `https://myapp.dev/...` with no configuration. Keep the
`omniauth-rails_csrf_protection` setup (sign-in buttons are `button_to ... method: :post`,
`data: { turbo: false }`).

If the callback still comes out as `http://` or `localhost` (a custom middleware stack,
or a request made without the proxy), pin it to the URL rb-portless injects:

```ruby
# config/initializers/omniauth.rb
OmniAuth.config.full_host = ENV["PORTLESS_URL"] if ENV["PORTLESS_URL"]
```

### Rodauth (`rodauth-omniauth`)

Same as OmniAuth: callbacks follow the request host. Set `omniauth_redirect_uri` or
OmniAuth's `full_host` from `PORTLESS_URL` only if they don't.

### Calling OAuth APIs from Ruby (`oauth2`, `Faraday`, `Net::HTTP`)

When your app is the OAuth client of another local app (e.g. a Doorkeeper provider at
`https://auth.myapp.dev`), point the client at that app's rb-portless URL:

```ruby
client = OAuth2::Client.new(ENV["CLIENT_ID"], ENV["CLIENT_SECRET"],
                            site: "https://auth.myapp.dev")
redirect_uri = "#{ENV.fetch('PORTLESS_URL', 'http://localhost:3000')}/oauth/callback"
```

rb-portless sets `SSL_CERT_FILE` in the child to a bundle that includes its local CA, so
these HTTPS calls verify without `VERIFY_NONE`. For a process started outside
rb-portless, use `SSL_CERT_FILE=~/.rb-portless/ca-bundle.pem`.

### Generic / Manual

Read the `PORTLESS_URL` environment variable rb-portless injects into the child process:

```ruby
base_url = ENV.fetch("PORTLESS_URL", "http://localhost:3000")
callback_url = "#{base_url}/auth/callback"
```

## Troubleshooting

### "redirect_uri_mismatch" or "invalid redirect URI"

The redirect URI sent during the flow doesn't match what's registered. Check:

1. The registered redirect URI matches the rb-portless URL exactly (protocol, host, path),
   including Devise's scope prefix (`/users/auth/...`)
2. The proxy is running with the right TLD (`rb-portless list`)
3. The `redirect_uri` the provider received (shown on its error page) starts with
   `https://` and your rb-portless host; if not, set `OmniAuth.config.full_host` (see above)

### "Blocked hosts" after switching TLD

Add the TLD to `config.hosts` (see The Fix). A leading-dot entry matches one label only:
`.dev` allows `myapp.dev` but not `api.myapp.dev`; add `.myapp.dev` for those.

### Provider requires HTTPS

`.dev` and `.app` are HSTS-preloaded, so browsers force HTTPS. rb-portless defaults to
HTTPS on port 443 (asks for sudo). Run `rb-portless trust` to add the local CA to the
system trust store and remove browser warnings.

### Apple rejects the domain

Apple may require the domain to resolve publicly. Add a DNS A record for your dev
subdomain pointing to `127.0.0.1`:

```
myapp.local.yourcompany.dev  A  127.0.0.1
```

Or use a wildcard: `*.local.yourcompany.dev  A  127.0.0.1`.

### Callback goes to the wrong URL after sign-in

The app is building the callback from `localhost` instead of the rb-portless domain.
Usually the app was started without rb-portless (no `PORTLESS_URL`) or reached directly
on its port. Open the rb-portless URL, or pin `OmniAuth.config.full_host` to
`PORTLESS_URL`.
