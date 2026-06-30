# frozen_string_literal: true

require "uri"

module Portless
  # The host matchers to whitelist in Rails development, derived from the URL
  # `portless-rb run` injects (PORTLESS_URL). Plain Ruby so it's testable without
  # booting Rails; the Railtie is just glue around it.
  module RailsHosts
    module_function

    # Empty unless we're actually running under portless-rb.
    def allowed(portless_url = ENV["PORTLESS_URL"])
      return [] if portless_url.to_s.empty?

      # Rails wraps a Regexp as /\A<re>(:port)?\z/, so match the whole host.
      patterns = [ /.+\.localhost/ ]

      host = begin
        URI(portless_url).host
      rescue StandardError
        nil
      end
      # Support a custom, non-.localhost tld (e.g. *.myapp.test) too.
      patterns.push(host, ".#{host}") if host && !host.end_with?(".localhost")
      patterns
    end
  end
end
