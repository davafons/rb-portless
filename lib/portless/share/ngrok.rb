# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Portless
  module Share
    # Expose the local app publicly via ngrok. We point ngrok at the *backend*
    # port directly (with the app's Host header) rather than tunnelling through
    # our self-signed TLS proxy — simpler and avoids cert-trust issues. Returns
    # { pid:, url: } or nil. EXPERIMENTAL. Mirrors portless's ngrok.ts.
    module Ngrok
      module_function

      API = "http://127.0.0.1:4040/api/tunnels"

      def start(hostname:, backend_port:)
        unless Portless.which("ngrok")
          warn "rb-portless: ngrok not found — install it (https://ngrok.com/download) to use --ngrok"
          return nil
        end

        pid = Process.spawn("ngrok", "http", backend_port.to_s, "--host-header=#{hostname}",
                            out: File::NULL, err: File::NULL)
        Process.detach(pid)

        if (url = poll_public_url)
          { pid: pid, url: url }
        else
          stop(pid: pid)
          warn "rb-portless: ngrok didn't produce a public URL — is your authtoken set? (`ngrok config add-authtoken <token>`)"
          nil
        end
      rescue StandardError => e
        warn "rb-portless: ngrok failed (#{e.message})"
        nil
      end

      def stop(handle)
        pid = handle.is_a?(Hash) ? handle[:pid] : handle
        Process.kill("TERM", pid) if pid
      rescue StandardError
        nil
      end

      def poll_public_url(tries: 25)
        tries.times do
          sleep 0.3
          body = fetch(API)
          next unless body

          tunnels = JSON.parse(body)["tunnels"] || []
          url = tunnels.map { |t| t["public_url"] }.compact.find { |u| u.start_with?("https") }
          return url if url
        end
        nil
      rescue StandardError
        nil
      end

      def fetch(url)
        Net::HTTP.get(URI(url))
      rescue StandardError
        nil
      end
    end
  end
end
