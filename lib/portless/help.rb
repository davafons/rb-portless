# frozen_string_literal: true

module Portless
  # Help texts, ported verbatim from portless's print*Help functions with
  # command examples renamed to rb-portless (and Node.js → Ruby where the
  # text describes the runtime). The first line of each is the bold title.
  module Help
    TEXTS = {
      "main" => <<~'TEXT',

        rb-portless - Run dev servers at stable .localhost URLs.

        Usage:
          rb-portless                         Run dev script through proxy
          rb-portless                         From monorepo root: run all workspace packages
          rb-portless run                     Same as above
          rb-portless run <cmd>               Run a command through the proxy
          rb-portless <name> <cmd>            Run with an explicit app name
          rb-portless proxy start             Start the proxy
          rb-portless proxy stop              Stop the proxy
          rb-portless mcp [--tools <profiles>] Start the stdio MCP server
          rb-portless service install         Start proxy automatically when the OS starts
          rb-portless get <name>              Print URL for a service
          rb-portless alias <name> <port>     Register a static route
          rb-portless alias --remove <name>   Remove a static route
          rb-portless compose up [args...]    Run a Docker Compose project
          rb-portless list                    Show active routes and uptime
          rb-portless doctor                  Check local rb-portless health
          rb-portless trust                   Add local CA to system trust store
          rb-portless clean                   Remove rb-portless state and trust entry
          rb-portless prune                   Clean up routes left by crashed sessions
          rb-portless hosts sync              Reconcile routes with /etc/hosts
          rb-portless hosts clean             Remove rb-portless entries from /etc/hosts

        Every command accepts --help or -h, which only prints help. After run <cmd>,
        compose <subcommand>, or --, they belong to the wrapped command.
        Value flags for run and named apps accept both --flag <value> and --flag=<value>.
        Forwarding arguments into a script with shell operators or a comment exits 2;
        run the command directly or make the script a single command. In Turbo mode
        only the root script is checked.

        Examples:
          rb-portless
          rb-portless -- --inspect
          rb-portless run next dev
          rb-portless --script start
          rb-portless myapp next dev
          rb-portless run --prefix pr-42 next dev
          rb-portless myapp --tailscale next dev

        Options:
          --script <name>               Select a package.json script in zero-argument mode
          --lan                         Enable LAN access for app commands
          --ip <address>                Pin the LAN IP (implies --lan)
          --tailscale                   Share the app on your tailnet
          --funnel                      Share the app publicly via Tailscale Funnel
          --ngrok                       Share the app publicly via ngrok
          --cloudflare                  Share the app publicly via a Cloudflare quick tunnel
          --                            Stop flag parsing and pass remaining arguments to the app

        Options for run and <name> <command>:
          --name <name>                 Set the app name or bypass command dispatch
          --force                       Kill the existing process and take over its route
          --app-port <number>           Use a fixed port for the app

        Environment variables:
          PORTLESS=0                    Run app commands directly without the proxy
          PORTLESS_PORT=<number>        Set the default proxy port
          PORTLESS_APP_PORT=<number>    Set a fixed port for the app
          PORTLESS_HTTPS=0              Disable HTTPS for the proxy
          PORTLESS_LAN=1                Enable LAN mode
          PORTLESS_TLD=<tld[,tld]>      Set one or more proxy TLDs
          PORTLESS_PREFIX=<label>       Set the worktree prefix; an empty value disables it

        Precedence: flags override PORTLESS_* variables, which override portless.json.
        Auto-start reuses the saved port, TLS, TLD, and LAN settings only after an
        unexpected proxy exit. A normal rb-portless proxy stop clears them.
        Proxy options: rb-portless proxy --help
        Run options: rb-portless run --help
        Run rb-portless <command> --help or visit https://portless.sh for details.

      TEXT
      "run" => <<~'TEXT',

        rb-portless run - Infer project name and run through the proxy.

        Usage:
          rb-portless run [options] [command...]

          When no command is given, runs the configured script (default: "dev")
          from package.json. Value flags accept both --flag <value> and --flag=<value>.

          Ctrl+C is forwarded to the command. Portless waits for its process tree to
          exit and terminates remaining descendants after a short grace period.

          On macOS and Linux, rb-portless exits with the reason when another user owns
          or can write to the state directory.

        Options:
          --name <name>          Override the inferred base name (worktree prefix still applies)
          --prefix <label>       Override the worktree label (an empty value disables it)
          --force                Kill the existing process and take over its route
          --app-port <number>    Use a fixed port for the app (skip auto-assignment)
          --tailscale            Share the app on your Tailscale network (tailnet)
          --funnel               Share the app publicly via Tailscale Funnel
          --ngrok                Share the app publicly via ngrok
          --cloudflare           Share the app publicly via a Cloudflare quick tunnel (requires cloudflared)
          --help, -h             Show this help

        Name inference (in order):
          1. portless.json "name" field
          2. package.json "name" field (walks up directories)
          3. Git repo root directory name
          4. Current directory basename

          In git worktrees the branch becomes a subdomain prefix (e.g.
          feature-auth.myapp.localhost); the default label is its last segment. Set
          "worktree.prefix" to "branch" for the whole branch, or
          "worktree.hostnameTemplate" with {worktree} and optional {name}. Templates
          must render valid DNS labels. --prefix and PORTLESS_PREFIX override detection;
          empty disables it. Template labels over 63 characters are hash-truncated.
          Duplicate proxied hostnames fail before apps start.

        Examples:
          rb-portless run                        # Run dev script through proxy
          rb-portless run next dev               # -> https://<project>.localhost
          rb-portless run --name myapp next dev  # -> https://myapp.localhost
          rb-portless run --prefix pr-42 next dev  # -> https://pr-42.<project>.localhost
          rb-portless run vite dev               # -> https://<project>.localhost
          rb-portless run --app-port 3000 pnpm start

      TEXT
      "get" => <<~'TEXT',

        rb-portless get - Print the URL for a service.

        Usage:
          rb-portless get <name>

        Uses the worktree config in the current directory, including workspace defaults,
        not the named app's package. Run from the target package for its per-app options.
        Invalid config fails instead of printing a guessed URL.
        PORTLESS_PREFIX="" skips worktree naming.

          BACKEND_URL=$(rb-portless get backend)

        Options:
          --no-worktree          Skip config loading and worktree naming
          --json                 Print name, hostname, and URL as JSON
          --help, -h             Show this help

        Examples:
          rb-portless get backend                  # -> https://backend.localhost
          rb-portless get backend                  # in worktree -> https://auth.backend.localhost
          rb-portless get backend --no-worktree    # -> https://backend.localhost (skip worktree)

      TEXT
      "list" => <<~'TEXT',

        rb-portless list - Show active routes and their uptime.

        Usage:
          rb-portless list [--json]

        Options:
          --json                 Print routes as JSON, including upstream settings when set
          --help, -h             Show this help

      TEXT
      "alias" => <<~'TEXT',

        rb-portless alias - Register a static route for services not managed by portless.

        Usage:
          rb-portless alias <name> <port>                 Register a route
          rb-portless alias <name> <port> --upstream https  Use HTTPS to the local backend
          rb-portless alias --remove <name>               Remove static routes, preserve process-owned routes
          rb-portless alias <name> <port> --force          Override an existing route

        Options:
          --force                   Override a route; stop a conflicting app if any
          --tld <tld>               Only these configured TLDs (repeatable, comma-separated)
          --upstream <value>        https, https://<host>[:<port>], or http://<host>[:<port>]
          --help, -h                Show this help

        On macOS and Linux, rb-portless exits with the reason when another user owns or
        can write to the state directory.

        The positional port always dials loopback. The value "https" enables TLS and
        preserves Host. An "https://" authority enables TLS and overrides Host with the full
        authority, including its optional port. SNI uses a DNS hostname without the port;
        IP addresses are not sent as SNI. An "http://" authority overrides Host without TLS.
        Upstream TLS connects only to an
        HTTP/1.1 backend on loopback. Certificate verification is disabled, so backend
        identity is not authenticated, including through an SSH tunnel. This does not change
        client-facing proxy TLS. Authorities accept only a hostname or IP with an optional
        port, without credentials, paths, queries, fragments, or whitespace. Restart the
        proxy daemon after upgrading.

        Examples:
          rb-portless alias my-postgres 5432      # -> https://my-postgres.localhost
          rb-portless alias redis 6379            # -> https://redis.localhost
          rb-portless alias redis 6379 --tld test # -> https://redis.test only
          rb-portless alias api 8080 --upstream https://api.internal
          rb-portless alias --remove my-postgres  # Remove the alias

      TEXT
      "proxy" => <<~'TEXT',

        rb-portless proxy - Manage the rb-portless proxy server.

        Usage:
          rb-portless proxy start                Start the HTTPS proxy on port 443 (daemon)
          rb-portless proxy start --no-tls       Start without HTTPS (port 80)
          rb-portless proxy start --lan          Enable LAN mode (mDNS, .local TLD)
          rb-portless proxy start --foreground   Start in foreground (for debugging)
          rb-portless proxy start -p 1355        Start on a custom port (also --port)
          rb-portless proxy start --unprivileged  Port 80 without sudo (443 with --https); plain HTTP unless --https
          rb-portless proxy start --https        Serve HTTPS, even with --unprivileged or PORTLESS_HTTPS=0
          rb-portless proxy start --cert <path> --key <path>  Use a custom certificate and key
          rb-portless proxy start --lan --ip <address>  Pin the LAN IP
          rb-portless proxy start --skip-trust   Do not add the CA to the system trust store
          rb-portless proxy start --tld test     Use .test instead of .localhost
          rb-portless proxy start --tld localhost --tld test  Serve both TLDs
          rb-portless proxy start --tld dev.example.com  Use a multi-segment TLD (production parity)
          rb-portless proxy start --wildcard     Allow unregistered subdomains to fall back to parent
          rb-portless proxy stop                 Stop the proxy

        Stop:
          Signals the recorded proxy only when nothing shows it is a different
          process from the one answering on the proxy port, and never from a state
          directory another user owns or can write to.

        State directory:
          The proxy exits instead of running on a state directory another user owns,
          can write to, or can redirect.

        LAN mode (--lan):
          Without LAN mode, the proxy listens only on 127.0.0.1 and ::1.
          LAN mode explicitly binds the proxy to 0.0.0.0 and ::.
          Makes services accessible from other devices on the same WiFi network
          via mDNS (.local domains). Useful for testing on real mobile devices.
          Auto-detects your LAN IP and follows changes automatically, or use
          --ip to pin one.

        Unprivileged mode (--unprivileged):
          Binds without sudo, installs nothing, and never writes the hosts file.
          Stopped proxies keep the mode; use PORTLESS_UNPRIVILEGED=0 to switch back.

      TEXT
      "service" => <<~'TEXT',

        rb-portless service - Start rb-portless automatically when the OS starts.

        Usage:
          rb-portless service install             Install and start the HTTPS service on port 443
          rb-portless service install --lan       Enable LAN mode for the startup service
          rb-portless service install -p 8443     Use a custom proxy port
          rb-portless service uninstall           Stop and remove the startup service
          rb-portless service status              Show service and proxy status

        Install options:
          -p, --port <number>              Port for the proxy service
          --no-tls                         Disable HTTPS
          --https                          Enable HTTPS
          --lan                            Enable LAN mode
          --ip <address>                   Pin a specific LAN IP
          --tld <tld>                      Use a custom TLD outside LAN mode, repeatable
          --wildcard                       Allow subdomain fallback
          --unprivileged                   Bind the wildcard address, loopback peers only, no elevation
          --cert <path>                    Use a custom TLS certificate
          --key <path>                     Use a custom TLS private key
          --state-dir <path>               Use a custom service state directory

        Notes:
          Value flags accept both --flag <value> and --flag=<value>.
          The service uses the default clean URL mode unless options or PORTLESS_*
          environment variables are provided during install.
          macOS and Linux install a root-owned service so port 443 can bind at boot.
          On macOS and Linux, install exits with the reason when another user owns,
          can write to, or can redirect the state directory.
          Windows installs a Task Scheduler startup task that runs as SYSTEM.

      TEXT
      "hosts" => <<~'TEXT',

        rb-portless hosts - Manage /etc/hosts entries for .localhost subdomains.

        Safari relies on the system DNS resolver, which may not handle .localhost
        subdomains. This command reconciles rb-portless-managed entries in /etc/hosts.

        Usage:
          rb-portless hosts sync    Reconcile current routes with /etc/hosts
          rb-portless hosts clean   Remove rb-portless entries from /etc/hosts

        Auto-sync:
          The proxy updates /etc/hosts for route hostnames by default.
          Disable hosts sync with PORTLESS_SYNC_HOSTS=0. If a route hostname
          will not resolve, the command that registered it warns instead of failing.

        Safety:
          Sync removes stale entries when there are no routes. It requires a successful
          hosts-file read before writing and verifies every write. Read or verification
          failures use the normal elevated privileges or error path.

      TEXT
      "doctor" => <<~'TEXT',

        rb-portless doctor - Check local rb-portless health and print suggested fixes.

        Usage:
          rb-portless doctor [--json]

        Checks Ruby, the state directory, proxy liveness, route entries, HTTPS CA
        trust, hostname resolution, and LAN mode prerequisites. It does not start,
        stop, clean, prune, trust, or modify rb-portless state.

        Options:
          --json                 Print the report as JSON
          --help, -h             Show this help

        Exit codes:
          0                      No failures; warnings do not affect the exit code
          1                      One or more failures
          2                      Invalid arguments

      TEXT
      "trust" => <<~'TEXT',

        rb-portless trust - Add the local CA to the system trust store.

        Generates the local CA first if it does not exist yet. Browsers and other
        clients then accept rb-portless HTTPS certificates. The OS may ask for
        authorization or sudo.

        On macOS and Linux, the state directory and each parent directory must be
        owned by you or root and not writable by group or others. A sticky parent
        such as /tmp is allowed. Otherwise trust exits with the reason.

        Usage:
          rb-portless trust

        Options:
          --help, -h             Show this help

      TEXT
      "clean" => <<~'TEXT',

        rb-portless clean - Remove rb-portless artifacts from this machine.

        Stops the proxy if it is running, uninstalls the startup service if installed,
        removes the local CA from the OS trust store when it was installed by rb-portless,
        deletes known files under state directories (~/.rb-portless and PORTLESS_STATE_DIR
        when set), and removes the rb-portless block
        from /etc/hosts.

        Only allowlisted filenames under each state directory are deleted. Custom
        certificate paths from --cert and --key are never removed. If trust removal
        fails, the CA certificate and key are retained so clean can safely retry.

        On macOS and Linux, a state directory that another user owns or can write to
        is left alone. Clean prints the reason and exits nonzero.

        On macOS and Linux, a privileged proxy stop or a failed trust-store, state-file,
        or /etc/hosts step is retried with sudo. The retry runs only those failed
        steps against the same allowlisted state directories. If the proxy cannot be
        confirmed stopped, its PID, port, runtime marker files, and CA files are kept
        and the CA stays trusted. On Windows, run as Administrator if needed.

        Usage:
          rb-portless clean

        Options:
          --yes, -y              Confirm cleanup without prompting
          --help, -h             Show this help

      TEXT
      "compose" => <<~'TEXT',

        rb-portless compose - Run a Docker Compose project behind rb-portless.

        Each service that publishes an HTTP port gets <service>.<project>.localhost.
        Database and cache ports such as 5432, 3306, 6379, and 27017 keep their
        published port.

        Usage:
          rb-portless compose up [args...]       Start the project and register routes
          rb-portless compose up -d [args...]    Start detached; routes stay until down
          rb-portless compose down [args...]     Stop the project and remove its routes
          rb-portless compose <command> [args]   Any other compose command, unchanged

        Global compose flags (-f, -p, --profile, --env-file, --project-directory) go
        before the command, as with docker compose.

        Examples:
          rb-portless compose up                  # -> https://web.myapp.localhost
          rb-portless compose -f compose.dev.yml up -d
          rb-portless compose down

        Service labels:
          portless.enable: "false"     Leave the service and its ports unchanged
          portless.name: <name>        Use <name> instead of the service name
          portless.ports: 3000,9229    Route only these container ports

        Notes:
          rb-portless picks a free port on 127.0.0.1 for each HTTP port and reuses it,
          so routes keep working after restart, after stop and start, and when Docker
          restarts the container. A routed service can't scale past one container.
          A service with several HTTP ports also gets <port>.<service>.<project>.
          Each routed service gets __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS, so a Vite
          dev server in a container accepts its rb-portless hostname.
          Start the project with rb-portless compose up, because a plain docker compose
          up recreates the containers with their original ports.

      TEXT
      "prune" => <<~'TEXT'

        rb-portless prune - Clean up routes left by crashed rb-portless sessions.

        Finds routes whose owning rb-portless process is gone, including groups kept from
        an earlier run. On macOS and Linux, it signals the recorded dev server process
        group only if its leader matches, or a previously recorded surviving member
        matches on retry, and reports the group stopped only after every member has
        exited. A group that outlives the signal keeps its route and shares even after
        it closes its port, and the member that survived is recorded so a retry with
        --force can stop it. A group that cannot be verified is reported and kept,
        never signaled, except that a member holding its port while the recorded
        leader is gone is recorded so --force can retry it. Stale routes and their
        Tailscale and tunnel shares are removed only once the recorded group is gone. A
        port holder that cannot be proven part of the recorded group is reported and
        kept, never killed. On Windows, process groups cannot be verified or signaled.
        Recorded ngrok and cloudflared tunnels are stopped only when their executable
        names match, including on Windows.

        Usage:
          rb-portless prune
          rb-portless prune --force     Send SIGKILL instead of SIGTERM

        Options:
          --force                Send SIGKILL instead of SIGTERM
          --help, -h             Show this help

      TEXT
    }.freeze

def print_help_text(key)
  lines = TEXTS.fetch(key).lines
  title = lines.index { |l| !l.strip.empty? }
  lines[title] = "#{Colors.bold(lines[title].chomp)}\n" if title
  puts lines.join
  0
end

    def print_help = print_help_text("main")
    def print_run_help = print_help_text("run")
    def print_get_help = print_help_text("get")
    def print_list_help = print_help_text("list")
    def print_alias_help = print_help_text("alias")
    def print_proxy_help = print_help_text("proxy")
    def print_service_help = print_help_text("service")
    def print_hosts_help = print_help_text("hosts")
    def print_doctor_help = print_help_text("doctor")
    def print_trust_help = print_help_text("trust")
    def print_clean_help = print_help_text("clean")
    def print_prune_help = print_help_text("prune")
    def print_compose_help = print_help_text("compose")
  end
end
