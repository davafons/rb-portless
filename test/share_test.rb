# frozen_string_literal: true

require_relative "test_helper"

# The sharing integrations degrade gracefully when the CLI tool isn't installed
# (the happy path needs ngrok/tailscale + accounts, so it's manual).
class ShareTest < Minitest::Test
  def test_ngrok_warns_and_skips_when_absent
    result = nil
    _out, err = capture_io do
      Portless.stub(:which, false) { result = Portless::Share::Ngrok.start(hostname: "x.localhost", backend_port: 4321) }
    end
    assert_nil result
    assert_match(/ngrok not found/, err)
    assert_match %r{ngrok.com/download}, err
  end

  def test_tailscale_warns_and_skips_when_absent
    result = nil
    _out, err = capture_io do
      Portless.stub(:which, false) { result = Portless::Share::Tailscale.start(backend_port: 4321) }
    end
    assert_nil result
    assert_match(/tailscale not found/, err)
    assert_match %r{tailscale.com/download}, err
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
