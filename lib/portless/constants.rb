# frozen_string_literal: true

module Portless
  module Constants
    # Where all coordination state lives (routes, CA, pid/port markers). Mirrors
    # portless's ~/.portless; overridable for tests / isolation.
    USER_STATE_DIR = File.expand_path(ENV["PORTLESS_STATE_DIR"] || "~/.portless-rb")

    # Default proxy ports: 443 for HTTPS (the default), 80 for --no-tls. When the
    # privileged port can't be bound (sudo denied), we fall back to 1355.
    HTTPS_PORT = 443
    HTTP_PORT = 80
    FALLBACK_PROXY_PORT = 1355
    PRIVILEGED_PORT_THRESHOLD = 1024

    # Backend app port range. Random-first assignment keeps the collision window
    # small; the WHATWG "bad ports" in range are skipped so browsers never reject.
    MIN_APP_PORT = 4000
    MAX_APP_PORT = 4999
    BLOCKED_PORTS = [ 4045, 4190, 4096 ].freeze # WHATWG bad-port set within 4000-4999

    # Default TLD. A project can override (e.g. "shirabe.org.localhost") so its
    # subdomains wildcard-route to one app.
    DEFAULT_TLD = "localhost"

    # The marker every proxied response carries, so we can tell *our* proxy from
    # any other process holding the port (used by the health probe).
    HEALTH_HEADER = "x-portless-rb"

    # /etc/hosts managed-block fences (Safari / non-.localhost TLDs).
    HOSTS_BEGIN = "# portless-rb-start"
    HOSTS_END = "# portless-rb-end"

    # Reject a dev-server loop that proxies back to us without changing origin.
    MAX_PROXY_HOPS = 5

    WINDOWS = (RbConfig::CONFIG["host_os"] =~ /mswin|mingw|cygwin/i) ? true : false
    MACOS = (RbConfig::CONFIG["host_os"] =~ /darwin/i) ? true : false
  end
end
