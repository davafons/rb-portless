# frozen_string_literal: true

module Portless
  # Most servers (Rails/puma, Express, Nuxt, …) honour the PORT env we inject.
  # A handful ignore it and need an explicit --port flag; some also need --host
  # so they bind loopback where the proxy expects them. We see through package
  # runners (npx/bunx/pnpm dlx/…). Mirrors portless's injectFrameworkFlags.
  module Frameworks
    module_function

    # basename => needs --strictPort
    NEEDS_PORT = {
      "vite" => true, "vp" => true, "react-router" => true, "rsbuild" => false,
      "astro" => false, "ng" => false, "react-native" => false, "expo" => false
    }.freeze

    RUNNERS = %w[npx bunx pnpm yarn dlx exec run].freeze

    def inject(command, port)
      base = framework_basename(command)
      return command unless NEEDS_PORT.key?(base)

      flags = [ "--port", port.to_s ]
      flags << "--strictPort" if NEEDS_PORT.fetch(base)
      flags += [ "--host", base == "expo" ? "localhost" : "127.0.0.1" ]
      command + flags
    end

    # The first argument that's a real command, seeing past package runners and
    # their subcommands (npx vite, pnpm exec astro, …).
    def framework_basename(command)
      command.each do |arg|
        next if arg.to_s.start_with?("-")

        base = File.basename(arg.to_s)
        next if RUNNERS.include?(base)

        return base
      end
      ""
    end
  end
end
