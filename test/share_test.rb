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

  # Safety: never reuse a port the user's existing serve config already occupies.
  def test_tailscale_picks_first_free_port
    Portless::Share::Tailscale.stub(:used_serve_ports, []) do
      assert_equal 443, Portless::Share::Tailscale.available_port(funnel: false)
    end
    Portless::Share::Tailscale.stub(:used_serve_ports, [ 443 ]) do
      assert_equal 8443, Portless::Share::Tailscale.available_port(funnel: false)
    end
    Portless::Share::Tailscale.stub(:used_serve_ports, [ 443, 8443 ]) do
      assert_equal 8444, Portless::Share::Tailscale.available_port(funnel: false)
    end
  end

  def test_tailscale_funnel_pool_exhausts_to_nil
    Portless::Share::Tailscale.stub(:used_serve_ports, [ 443, 8443, 10_000 ]) do
      assert_nil Portless::Share::Tailscale.available_port(funnel: true)
    end
  end
end
