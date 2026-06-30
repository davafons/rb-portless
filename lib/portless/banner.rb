# frozen_string_literal: true

module Portless
  # The "where is my app" banner printed to stderr when a dev server starts
  # through rb-portless — so you see the named URL, not just 127.0.0.1:port.
  # Vite-ish layout; colours are stripped when stderr isn't a TTY. Mirrors the
  # spirit of portless's run output.
  module Banner
    module_function

    # rows: ordered [label, value, color] for the reachable URLs (Local,
    # Network, Public, …); backend is the real 127.0.0.1:port behind the proxy.
    def app(rows:, backend_port:)
      out = [ "", "  #{bold('rb-portless')} #{dim("v#{VERSION}")}", "" ]
      rows.each { |label, value, paint| out << row(label, send(paint || :cyan, value)) }
      out << row("Backend", dim("127.0.0.1:#{backend_port}"))
      out << ""
      out << "  #{dim('ready — press Ctrl-C to stop')}"
      out << ""
      warn out.join("\n")
    end

    # Multi-app: one row per app (name → URL).
    def multi(apps:)
      out = [ "", "  #{bold('rb-portless')} #{dim("v#{VERSION}")}", "" ]
      apps.each { |app| out << row(app.name, cyan(app.url)) }
      out << ""
      out << "  #{dim('ready — press Ctrl-C to stop')}"
      out << ""
      warn out.join("\n")
    end

    def row(label, value) = "  #{green('➜')}  #{label.to_s.ljust(8)}#{value}"

    # ── colours (no-op unless stderr is a TTY) ──
    def paint(code, str) = tty? ? "\e[#{code}m#{str}\e[0m" : str
    def bold(str)  = paint("1", str)
    def dim(str)   = paint("90", str)
    def cyan(str)  = paint("36", str)
    def green(str) = paint("32", str)
    def tty? = $stderr.tty?
  end
end
