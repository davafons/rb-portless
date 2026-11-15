# frozen_string_literal: true

module Portless
  module Constants
    # Default location for all coordination state (routes, CA, pid/port markers).
    # Upstream uses ~/.portless; ours differs so both can coexist. State.dir
    # reads PORTLESS_STATE_DIR at call time.
    DEFAULT_STATE_DIR = "~/.rb-portless"

    # Default proxy ports: 443 for HTTPS (the default), 80 for --no-tls, and
    # 1355 for --unprivileged / legacy setups.
    HTTPS_PORT = 443
    HTTP_PORT = 80
    FALLBACK_PROXY_PORT = 1355
    DEFAULT_PROXY_PORT = FALLBACK_PROXY_PORT
    PRIVILEGED_PORT_THRESHOLD = 1024

    # Backend app port range (cli-utils.ts).
    MIN_APP_PORT = 4000
    MAX_APP_PORT = 4999

    # WHATWG "bad ports" a browser refuses to connect to (cli-utils.ts BLOCKED_PORTS).
    # @see https://fetch.spec.whatwg.org/#port-blocking
    BLOCKED_PORTS = [
      0, 1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 69, 77, 79, 87, 95, 101, 102,
      103, 104, 109, 110, 111, 113, 115, 117, 119, 123, 135, 137, 139, 143, 161, 179, 389, 427, 465,
      512, 513, 514, 515, 526, 530, 531, 532, 540, 548, 554, 556, 563, 587, 601, 636, 989, 990, 993,
      995, 1719, 1720, 1723, 2049, 3659, 4045, 4190, 5060, 5061, 6000, 6566, 6665, 6666, 6667, 6668,
      6669, 6679, 6697, 10080
    ].freeze

    DEFAULT_TLD = "localhost"

    # Response header that identifies a portless proxy (health checks). Every
    # proxy-generated or proxied response carries `X-Portless: 1`.
    PORTLESS_HEADER = "X-Portless"
    HEALTH_HEADER = "x-portless"

    # Request header counting passes through a portless proxy (loop detection).
    PORTLESS_HOPS_HEADER = "x-portless-hops"
    # Two hops is normal (frontend → API through portless); five catches loops.
    MAX_PROXY_HOPS = 5

    # The daemon-owned hosts sync endpoint (proxy.ts HOSTS_SYNC_PATH).
    HOSTS_SYNC_PATH = "/.portless/hosts-sync"

    # /etc/hosts managed-block fences. Upstream uses "# portless-start/end";
    # ours differ so both tools can manage their own block.
    HOSTS_BEGIN = "# rb-portless-start"
    HOSTS_END = "# rb-portless-end"

    WINDOWS = (RbConfig::CONFIG["host_os"] =~ /mswin|mingw|cygwin/i) ? true : false
    MACOS = (RbConfig::CONFIG["host_os"] =~ /darwin/i) ? true : false
  end
end
