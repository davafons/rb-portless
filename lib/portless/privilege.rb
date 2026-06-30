# frozen_string_literal: true

require "rbconfig"

module Portless
  # The whole privileged-port trick (ports < 1024): re-exec the CLI under sudo so
  # the elevated process binds the socket itself, then chown state files back to
  # the invoking user. Fall back to the unprivileged port 1355 if sudo is denied
  # and no explicit port was asked for. Refuse silently-in-CI. Mirrors portless.
  module Privilege
    module_function

    def root? = Process.respond_to?(:uid) && Process.uid.zero?

    def privileged_port?(port) = port.to_i < Constants::PRIVILEGED_PORT_THRESHOLD

    def needs_sudo?(port)
      !Constants::WINDOWS && privileged_port?(port) && !root?
    end

    # A real terminal we can prompt on. CI / no-TTY must never hang on a sudo
    # password — callers turn this into a clear error or the 1355 fallback.
    def interactive?
      $stdin.tty? && $stdout.tty? && !truthy(ENV["CI"])
    end

    # Re-run *this* CLI under sudo, preserving PORTLESS_* env (sudo strips env).
    # Returns true on success. stdio is inherited so the password prompt shows.
    def reexec_with_sudo(args)
      cmd = [ "sudo", "env", *portless_env_args, RbConfig.ruby, program, *args ]
      system(*cmd)
    end

    def portless_env_args
      ENV.select { |k, _| k.start_with?("PORTLESS") }.map { |k, v| "#{k}=#{v}" }
    end

    # The executable to re-invoke. $PROGRAM_NAME is the exe path (gem wrapper or
    # exe/rb-portless in dev).
    def program = $PROGRAM_NAME

    def truthy(value) = %w[1 true yes].include?(value.to_s.downcase)
  end
end
