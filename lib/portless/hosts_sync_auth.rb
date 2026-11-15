# frozen_string_literal: true

require "openssl"
require "securerandom"
require "fileutils"

module Portless
  # Token auth for the daemon's hosts sync endpoint. The daemon writes a random
  # token to the state dir; a CLI proves it can read that file before asking the
  # proxy to sync /etc/hosts. Mirrors portless's hosts-sync-auth.ts.
  module HostsSyncAuth
    module_function

    HOSTS_SYNC_AUTH_FILE = "proxy.hosts-sync-token"
    HOSTS_SYNC_AUTH_TEMP_FILE = "#{HOSTS_SYNC_AUTH_FILE}.tmp".freeze
    HOSTS_SYNC_AUTH_HEADER = "x-portless-hosts-sync-token"
    HOSTS_SYNC_AUTH_CHALLENGE_HEADER = "x-portless-hosts-sync-challenge"
    HOSTS_SYNC_AUTH_PROOF_HEADER = "x-portless-hosts-sync-proof"

    # Short aliases.
    FILE = HOSTS_SYNC_AUTH_FILE
    HEADER = HOSTS_SYNC_AUTH_HEADER
    CHALLENGE_HEADER = HOSTS_SYNC_AUTH_CHALLENGE_HEADER
    PROOF_HEADER = HOSTS_SYNC_AUTH_PROOF_HEADER

    PATTERN = /\A[a-f0-9]{64}\z/

    def valid_token?(value) = value.is_a?(String) && PATTERN.match?(value)

    def generate_token = SecureRandom.hex(32)
    def generate_challenge = generate_token

    # HMAC-SHA256(token, challenge) as hex, or nil when either is malformed.
    def create_proof(token, challenge)
      return nil unless valid_token?(token) && valid_token?(challenge)

      OpenSSL::HMAC.hexdigest("SHA256", token, challenge)
    end

    def secure_compare(a, b)
      a.bytesize == b.bytesize && OpenSSL.fixed_length_secure_compare(a, b)
    end

    def write_token(dir, token)
      return false unless valid_token?(token)

      token_path = File.join(dir, HOSTS_SYNC_AUTH_FILE)
      temp_path = File.join(dir, HOSTS_SYNC_AUTH_TEMP_FILE)
      FileUtils.rm_f(temp_path)
      File.open(temp_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(token) }
      State.fix_ownership(temp_path)
      File.rename(temp_path, token_path)
      true
    rescue StandardError
      FileUtils.rm_f(temp_path) rescue nil
      false
    end

    def read_token(dir)
      token = File.read(File.join(dir, HOSTS_SYNC_AUTH_FILE)).strip
      valid_token?(token) ? token : nil
    rescue StandardError
      nil
    end

    def remove_token(dir)
      [ HOSTS_SYNC_AUTH_FILE, HOSTS_SYNC_AUTH_TEMP_FILE ].each do |name|
        FileUtils.rm_f(File.join(dir, name))
      rescue StandardError
        next
      end
    end
  end
end
