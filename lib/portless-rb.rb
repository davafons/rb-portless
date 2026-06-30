# frozen_string_literal: true

# portless-rb — stable, named .localhost URLs for local dev (a native-Ruby port
# of Vercel's portless). See AGENTS.md for the architecture map.
require_relative "portless/version"
require_relative "portless/constants"
require_relative "portless/state"
require_relative "portless/config"
require_relative "portless/free_port"
require_relative "portless/route_store"
require_relative "portless/health"
require_relative "portless/privilege"
require_relative "portless/hosts"
require_relative "portless/certs"
require_relative "portless/trust"
require_relative "portless/proxy"
require_relative "portless/daemon"
require_relative "portless/service"
require_relative "portless/runner"
require_relative "portless/cli"

module Portless
  class Error < StandardError; end

  # Raised when a privileged action can't run non-interactively (no TTY / CI).
  class NonInteractiveError < Error; end
end
