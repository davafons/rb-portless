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

  # The pure parsers, over fixture JSON shaped like the tailscale CLI's output.
  def test_tailscale_used_ports_parses_web_and_tcp_entries
    config = { "Web" => { "node.tail1234.ts.net:8443" => {} }, "TCP" => { "10000" => {} } }
    assert_equal [ 8443, 10_000 ], Portless::Share::Tailscale.used_serve_ports(config).sort
    assert_empty Portless::Share::Tailscale.used_serve_ports({})
  end

  def test_tailscale_capability_and_dns_name_parsing
    status = { "Self" => { "DNSName" => "node.tail1234.ts.net.",
                           "Capabilities" => [ "https://tailscale.com/cap/funnel" ],
                           "CapMap" => { "https" => nil } } }
    assert Portless::Share::Tailscale.capability?(status, "https")
    assert Portless::Share::Tailscale.capability?(status, "funnel")
    refute Portless::Share::Tailscale.capability?(status, "ssh")
    assert_equal "https://node.tail1234.ts.net", Portless::Share::Tailscale.dns_name(status)
    assert_nil Portless::Share::Tailscale.dns_name({})
  end

  def test_tailscale_format_url_drops_only_the_default_port
    assert_equal "https://n.ts.net", Portless::Share::Tailscale.format_url("https://n.ts.net", 443)
    assert_equal "https://n.ts.net:8443", Portless::Share::Tailscale.format_url("https://n.ts.net", 8443)
  end

  # clean/prune teardown knows only the recorded URL — the port comes from it,
  # and with the mode unrecorded both are turned off.
  def test_tailscale_stop_url_turns_off_both_modes_on_the_url_port
    calls = []
    Portless.stub(:which, true) do
      Portless::Share::Tailscale.stub(:off, ->(mode, port) { calls << [ mode, port ] }) do
        Portless::Share::Tailscale.stop_url("https://node.ts.net:8443")
      end
    end
    assert_equal [ [ "serve", 8443 ], [ "funnel", 8443 ] ], calls

    calls.clear
    Portless.stub(:which, true) do
      Portless::Share::Tailscale.stub(:off, ->(mode, port) { calls << [ mode, port ] }) do
        Portless::Share::Tailscale.stop_url("https://node.ts.net")
      end
    end
    assert_equal [ [ "serve", 443 ], [ "funnel", 443 ] ], calls
  end
end
