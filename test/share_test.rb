# frozen_string_literal: true

require_relative "test_helper"

# The sharing integrations degrade gracefully when the CLI tool isn't installed
# (the happy path needs ngrok/tailscale + accounts, so it's manual).
class ShareTest < Minitest::Test
  def test_ngrok_skips_when_absent
    Portless.stub(:which, false) do
      assert_nil Portless::Share::Ngrok.start(hostname: "x.localhost", backend_port: 4321)
    end
  end

  def test_tailscale_skips_when_absent
    Portless.stub(:which, false) do
      assert_nil Portless::Share::Tailscale.start(backend_port: 4321)
    end
  end
end
