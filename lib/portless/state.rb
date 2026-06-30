# frozen_string_literal: true

require "fileutils"

module Portless
  # The on-disk state directory (~/.portless-rb): the single source of
  # coordination — routes, CA, and pid/port/marker files. No daemon IPC; the
  # proxy watches routes.json and everything else is plain files. Mirrors
  # portless's state-dir model.
  module State
    module_function

    # Read the env at call time so an override (tests, or the PORTLESS_STATE_DIR
    # we pass to the sudo'd daemon) is always respected.
    def dir = File.expand_path(ENV["PORTLESS_STATE_DIR"] || Constants::DEFAULT_STATE_DIR)

    def path(name) = File.join(dir, name)

    def ensure_dir!
      FileUtils.mkdir_p(dir, mode: 0o755)
      dir
    end

    # File locations (1:1 with portless's state files).
    def routes_file = path("routes.json")
    def routes_lock = path("routes.lock")
    def proxy_pid_file = path("proxy.pid")
    def proxy_port_file = path("proxy.port")
    def proxy_log = path("proxy.log")
    def ca_cert = path("ca.pem")
    def ca_key = path("ca-key.pem")
    def ca_serial = path("ca.srl")
    def ca_trusted_marker = path("ca.trusted")
    def host_certs_dir = path("host-certs")

    # When we wrote files while elevated (root), hand them back to the invoking
    # user so the unprivileged CLI can still read/write routes.json. Keyed on the
    # SUDO_UID/SUDO_GID sudo exposes. No-op when not running as root.
    def fix_ownership(target = dir)
      return unless Process.respond_to?(:uid) && Process.uid.zero?

      uid = Integer(ENV["SUDO_UID"], exception: false)
      gid = Integer(ENV["SUDO_GID"], exception: false)
      return unless uid

      FileUtils.chown_R(uid, gid, target, force: true)
    rescue StandardError
      # Best-effort; never fail a command over ownership fix-ups.
      nil
    end
  end
end
