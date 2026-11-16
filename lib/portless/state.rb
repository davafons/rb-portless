# frozen_string_literal: true

require "fileutils"
require "etc"

module Portless
  # The on-disk state directory (~/.rb-portless): the single source of
  # coordination — routes, CA, and pid/port/marker files. No daemon IPC; the
  # proxy watches routes.json and everything else is plain files. Mirrors
  # portless's utils.ts (resolveUserHome, fixOwnership, state-dir safety checks)
  # and the state-file names in cli-utils.ts.
  module State
    module_function

    STATE_DIR_MODE = 0o755
    MAX_SYMLINK_HOPS = 40

    # Read the env at call time so an override (tests, or the PORTLESS_STATE_DIR
    # we pass to the sudo'd daemon) is always respected. resolveStateDir.
    def dir
      env = ENV["PORTLESS_STATE_DIR"]
      return env if env && !env.empty?

      user_state_dir
    end

    # ~/.rb-portless whatever PORTLESS_STATE_DIR says (USER_STATE_DIR): where
    # upstream keeps per-user files such as the Turbo env loader.
    def user_state_dir = File.join(resolve_user_home, File.basename(Constants::DEFAULT_STATE_DIR))

    # The home that owns rb-portless state. Under sudo keep the invoking user's
    # home so the elevated proxy and unprivileged apps share one route store.
    # utils.ts resolveUserHome.
    def resolve_user_home(env: ENV, windows: Constants::WINDOWS, macos: Constants::MACOS,
                          homedir: Dir.home, passwd_home: method(:read_passwd_home))
      return env["USERPROFILE"] || homedir if windows

      sudo_user = env["SUDO_USER"]
      return homedir if sudo_user.nil? || sudo_user.empty? || sudo_user == "root"

      home = env["HOME"]
      return home if home && !home.empty? && home != "/root" && home != "/var/root"

      from_passwd = passwd_home.call(sudo_user)
      return from_passwd if from_passwd

      macos ? File.join("/Users", sudo_user) : File.join("/home", sudo_user)
    end

    def read_passwd_home(username)
      File.foreach("/etc/passwd") do |line|
        fields = line.chomp.split(":")
        return fields[5] if fields[0] == username && fields[5] && !fields[5].empty?
      end
      nil
    rescue StandardError
      nil
    end

    def path(name, base = dir) = File.join(base, name)

    def ensure_dir!
      FileUtils.mkdir_p(dir, mode: STATE_DIR_MODE)
      dir
    end

    def ca_cert = path("ca.pem")

    # When we wrote files while elevated (root), hand them back to the invoking
    # user so the unprivileged CLI can still read/write them. Keyed on the
    # SUDO_UID/SUDO_GID sudo exposes. No-op unless running as root. Only the
    # given paths, never following symlinks. utils.ts fixOwnership.
    def fix_ownership(*paths)
      return if Constants::WINDOWS || !Process.uid.zero?

      uid = Integer(ENV["SUDO_UID"].to_s, exception: false)
      return unless uid

      gid = Integer(ENV["SUDO_GID"].to_s, exception: false) || uid
      paths.each do |path|
        File.lchown(uid, gid, path) unless File.lstat(path).symlink?
      rescue StandardError
        nil # best-effort
      end
      nil
    end

    # ── State-dir safety (utils.ts findStateDirProblem & friends) ─────────────

    # UIDs allowed to own a state directory: root, us, and under sudo the
    # invoking user. nil on Windows (no ownership model to check).
    def allowed_owners
      return nil if Constants::WINDOWS

      uid = Process.uid
      owners = [ 0, uid ]
      if uid.zero?
        sudo_uid = Integer(ENV["SUDO_UID"].to_s, exception: false)
        owners << sudo_uid if sudo_uid && sudo_uid >= 0
      end
      owners.uniq
    end

    # First directory from `start` up to / that another user could use to swap
    # what lies below it, or nil when all are safe.
    def find_unsafe_dir_in_chain(start, owners)
      current = start
      loop do
        begin
          stat = File.lstat(current)
          return current unless stat.directory?
          return current unless owners.include?(stat.uid)

          writable_by_others = stat.mode.anybits?(0o022)
          sticky = stat.mode.anybits?(0o1000)
          return current if writable_by_others && !sticky
        rescue SystemCallError
          return current
        end
        parent = File.dirname(current)
        return nil if parent == current

        current = parent
      end
    end

    # realpath that refuses symlinks another user could create or retarget.
    # Returns [:path, p] | [:unsafe, p] | [:missing, p].
    def resolve_trusted_path(target, owners)
      absolute = File.expand_path(target)
      root = "/"
      pending = absolute.split("/").reject(&:empty?)
      current = root
      hops = 0
      until pending.empty?
        nxt = File.join(current, pending.shift)
        begin
          stat = File.lstat(nxt)
        rescue SystemCallError
          return [ :missing, nxt ]
        end
        unless stat.symlink?
          current = nxt
          next
        end
        hops += 1
        return [ :unsafe, nxt ] if hops > MAX_SYMLINK_HOPS || !owners.include?(stat.uid)

        holder = find_unsafe_dir_in_chain(current, owners)
        return [ :unsafe, holder ] if holder

        begin
          linked = File.expand_path(File.readlink(nxt), current)
        rescue SystemCallError
          return [ :missing, nxt ]
        end
        pending = linked.split("/").reject(&:empty?) + pending
        current = root
      end
      [ :path, current ]
    end

    def find_unsafe_state_dir_ancestor(target, owners)
      kind, resolved = resolve_trusted_path(target, owners)
      return resolved if kind == :unsafe
      return File.dirname(target) if kind == :missing

      find_unsafe_dir_in_chain(File.dirname(resolved), owners)
    end

    # Why a state dir can't be trusted to name a CA, a process to signal, or
    # elevated work: {reason:, path:} or nil. utils.ts findStateDirProblem.
    def find_problem(target)
      begin
        stat = File.lstat(target)
      rescue SystemCallError
        return { reason: :not_directory, path: target }
      end
      return { reason: :not_directory, path: target } unless stat.directory?

      owners = allowed_owners
      return nil unless owners
      return { reason: :foreign_owner, path: target } unless owners.include?(stat.uid)

      ancestor = find_unsafe_state_dir_ancestor(target, owners)
      return { reason: :unsafe_parent, path: ancestor } if ancestor
      return { reason: :writable_by_others, path: target } if stat.mode.anybits?(0o022)

      nil
    end

    def cleanable?(target) = find_problem(target).nil?

    def locate(target)
      owners = allowed_owners
      if owners
        kind, resolved = resolve_trusted_path(target, owners)
        return [ nil, { reason: :unsafe_link, path: resolved } ] if kind == :unsafe
        return [ nil, { reason: :unresolvable, path: resolved } ] if kind == :missing

        canonical = resolved
      else
        begin
          canonical = File.realpath(target)
        rescue SystemCallError
          return [ nil, { reason: :unresolvable, path: target } ]
        end
      end
      [ canonical, find_problem(canonical) ]
    end

    def describe_problem(problem)
      return nil unless problem

      case problem[:reason]
      when :unresolvable then "it cannot be resolved"
      when :not_directory then "it is not a directory"
      when :foreign_owner then "it is owned by another user"
      when :writable_by_others then "other users can write to it. Run: chmod go-w #{problem[:path]}"
      when :unsafe_parent then "other users can replace it through #{problem[:path]}"
      when :unsafe_link then "other users can redirect it through #{problem[:path]}"
      end
    end

    # A sentence fragment saying why a state dir is refused, or nil when safe.
    # utils.ts explainUnsafeStateDir.
    def explain_unsafe_state_dir(target = dir) = describe_problem(locate(target)[1])
    # Kept for cli.rb's trust handler until it calls explain_unsafe_state_dir.
    def explain_unsafe(target = dir) = explain_unsafe_state_dir(target)

    # Create the dir if missing and make it owner-writable only; returns why it
    # is still unsafe, or nil. utils.ts ensureStateDir.
    def ensure_state_dir(target = dir)
      canonical, problem = locate(target)
      if problem && problem[:reason] == :unresolvable
        FileUtils.mkdir_p(target, mode: STATE_DIR_MODE)
        canonical, problem = locate(target)
      end
      return describe_problem(problem) if canonical.nil? || Constants::WINDOWS

      if problem.nil?
        begin
          File.chmod(STATE_DIR_MODE, canonical) unless File.symlink?(canonical)
        rescue SystemCallError
          nil
        end
        fix_ownership(canonical)
        return nil
      end
      describe_problem(problem)
    end

    # Prepare a state dir for use; raises when another user controls it.
    # utils.ts requireStateDir.
    def require_state_dir(target = dir)
      unsafe = ensure_state_dir(target)
      raise Error, "Cannot use state directory #{target}: #{unsafe}" if unsafe && !Constants::WINDOWS

      target
    end
  end
end
