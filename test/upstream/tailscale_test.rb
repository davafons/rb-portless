# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/share"
require "json"
require "set"

# Mirror of packages/portless/src/tailscale.test.ts

describe "tailscale" do
  ts = Portless::Share::Tailscale

  # tailscale.test.ts createRunner: canned results keyed by the joined args.
  define_method(:create_runner) do |results, calls = []|
    lambda do |args|
      calls << args
      key = args.join(" ")
      result = results[key] or raise "Unexpected tailscale call: #{key}"
      out = { status: result.key?(:status) ? result[:status] : 0, stdout: result[:stdout] || "",
              stderr: result[:stderr] || "" }
      out[:error] = result[:error] if result[:error]
      out
    end
  end

  # -----------------------------------------------------------------------
  # ensureTailscaleReady
  # -----------------------------------------------------------------------

  describe "ensureTailscaleReady" do
    it "resolves base URL from Self.DNSName" do
      runner = create_runner({
                               "version" => { status: 0 },
                               "status --json" => {
                                 status: 0,
                                 stdout: JSON.generate({ Self: { DNSName: "devbox.example.ts.net." } })
                               }
                             })
      ready = ts.ensure_tailscale_ready(runner: runner)
      _(ready[:dns_name]).must_equal "devbox.example.ts.net"
      _(ready[:base_url]).must_equal "https://devbox.example.ts.net"
    end

    it "falls back to HostName and MagicDNSSuffix" do
      runner = create_runner({
                               "version" => { status: 0 },
                               "status --json" => {
                                 status: 0,
                                 stdout: JSON.generate({
                                                         Self: { HostName: "devbox" },
                                                         CurrentTailnet: { MagicDNSSuffix: "example.ts.net." }
                                                       })
                               }
                             })
      ready = ts.ensure_tailscale_ready(runner: runner)
      _(ready[:dns_name]).must_equal "devbox.example.ts.net"
    end

    it "throws when Funnel is required but not enabled on the tailnet" do
      runner = create_runner({
                               "version" => { status: 0 },
                               "status --json" => {
                                 status: 0,
                                 stdout: JSON.generate({
                                                         Self: {
                                                           ID: "nMNPgMjBts11CNTRL",
                                                           DNSName: "devbox.example.ts.net.",
                                                           Capabilities: [ "https" ]
                                                         }
                                                       })
                               }
                             })
      err = _ { ts.ensure_tailscale_ready(runner: runner, require_funnel: true) }.must_raise Portless::Error
      _(err.message).must_include "https://login.tailscale.com/f/funnel?node=nMNPgMjBts11CNTRL"
    end

    it "validates node DNS before checking required capabilities" do
      runner = create_runner({
                               "version" => { status: 0 },
                               "status --json" => { status: 0, stdout: JSON.generate({ Self: {} }) }
                             })
      err = _ do
        ts.ensure_tailscale_ready(runner: runner, require_funnel: true, require_https: true)
      end.must_raise Portless::Error
      _(err.message).must_include "Could not determine Tailscale node DNS name"
    end

    it "throws when HTTPS is required but not enabled on the tailnet" do
      runner = create_runner({
                               "version" => { status: 0 },
                               "status --json" => {
                                 status: 0,
                                 stdout: JSON.generate({
                                                         Self: {
                                                           DNSName: "devbox.example.ts.net.",
                                                           Capabilities: [ "funnel" ]
                                                         }
                                                       })
                               }
                             })
      err = _ { ts.ensure_tailscale_ready(runner: runner, require_https: true) }.must_raise Portless::Error
      _(err.message).must_include "Tailscale HTTPS is not enabled on your tailnet"
    end

    it "allows HTTPS when the node has an HTTPS capability" do
      runner = create_runner({
                               "version" => { status: 0 },
                               "status --json" => {
                                 status: 0,
                                 stdout: JSON.generate({
                                                         Self: {
                                                           DNSName: "devbox.example.ts.net.",
                                                           CapMap: { https: nil }
                                                         }
                                                       })
                               }
                             })
      ready = ts.ensure_tailscale_ready(runner: runner, require_https: true)
      _(ready[:base_url]).must_equal "https://devbox.example.ts.net"
    end

    it "allows Funnel when the node has a Funnel capability" do
      runner = create_runner({
                               "version" => { status: 0 },
                               "status --json" => {
                                 status: 0,
                                 stdout: JSON.generate({
                                                         Self: {
                                                           DNSName: "devbox.example.ts.net.",
                                                           Capabilities: [ "https", "https://tailscale.com/cap/funnel" ]
                                                         }
                                                       })
                               }
                             })
      ready = ts.ensure_tailscale_ready(runner: runner, require_funnel: true)
      _(ready[:base_url]).must_equal "https://devbox.example.ts.net"
    end

    it "throws when tailscale CLI is missing" do
      enoent = Errno::ENOENT.new("spawn tailscale")
      runner = create_runner({ "version" => { status: nil, error: enoent } })
      err = _ { ts.ensure_tailscale_ready(runner: runner) }.must_raise Portless::Error
      _(err.message).must_include "Tailscale CLI not found"
    end

    it "throws when tailscale is not connected" do
      runner = create_runner({
                               "version" => { status: 0 },
                               "status --json" => { status: 0, stdout: JSON.generate({ Self: {} }) }
                             })
      err = _ { ts.ensure_tailscale_ready(runner: runner) }.must_raise Portless::Error
      _(err.message).must_include "Could not determine"
    end

    it "throws on version check failure" do
      runner = create_runner({ "version" => { status: 1, stderr: "not found" } })
      err = _ { ts.ensure_tailscale_ready(runner: runner) }.must_raise Portless::Error
      _(err.message).must_include "Failed to check tailscale version"
    end

    it "throws on invalid status JSON" do
      runner = create_runner({
                               "version" => { status: 0 },
                               "status --json" => { status: 0, stdout: "not json" }
                             })
      err = _ { ts.ensure_tailscale_ready(runner: runner) }.must_raise Portless::Error
      _(err.message).must_include "Failed to parse"
    end
  end

  # -----------------------------------------------------------------------
  # getUsedServePorts
  # -----------------------------------------------------------------------

  describe "getUsedServePorts" do
    it "parses Web ports from serve status JSON" do
      runner = create_runner({
                               "serve status --json" => {
                                 status: 0,
                                 stdout: JSON.generate({
                                                         Web: {
                                                           "devbox.example.ts.net:443" => { Handlers: {} },
                                                           "devbox.example.ts.net:8443" => { Handlers: {} }
                                                         }
                                                       })
                               }
                             })
      ports = ts.get_used_serve_ports(runner)
      _(ports).must_equal Set[443, 8443]
    end

    it "parses TCP ports" do
      runner = create_runner({
                               "serve status --json" => {
                                 status: 0,
                                 stdout: JSON.generate({ TCP: { "22" => { HTTPS: true }, "443" => {} } })
                               }
                             })
      ports = ts.get_used_serve_ports(runner)
      _(ports).must_equal Set[22, 443]
    end

    it "includes ports held by foreground serve or funnel sessions" do
      runner = create_runner({
                               "serve status --json" => {
                                 status: 0,
                                 stdout: JSON.generate({
                                                         TCP: { "8443" => { HTTPS: true } },
                                                         Web: { "devbox.example.ts.net:8443" => { Handlers: {} } },
                                                         Foreground: {
                                                           df16b397a48601e8: {
                                                             TCP: { "443" => { HTTPS: true } },
                                                             Web: { "devbox.example.ts.net:443" => { Handlers: {} } },
                                                             AllowFunnel: { "devbox.example.ts.net:443" => true }
                                                           }
                                                         }
                                                       })
                               }
                             })
      ports = ts.get_used_serve_ports(runner)
      _(ports).must_equal Set[443, 8443]
    end

    it "returns empty set on command failure" do
      runner = create_runner({ "serve status --json" => { status: 1, stderr: "error" } })
      ports = ts.get_used_serve_ports(runner)
      _(ports).must_equal Set.new
    end

    it "returns empty set on invalid JSON" do
      runner = create_runner({ "serve status --json" => { status: 0, stdout: "not json" } })
      ports = ts.get_used_serve_ports(runner)
      _(ports).must_equal Set.new
    end

    it "returns empty set on empty config" do
      runner = create_runner({ "serve status --json" => { status: 0, stdout: "{}" } })
      ports = ts.get_used_serve_ports(runner)
      _(ports).must_equal Set.new
    end
  end

  # -----------------------------------------------------------------------
  # findAvailableServePort
  # -----------------------------------------------------------------------

  describe "findAvailableServePort" do
    it "returns 443 when nothing is in use" do
      _(ts.find_available_serve_port(Set.new)).must_equal 443
    end

    it "returns 8443 when 443 is taken" do
      _(ts.find_available_serve_port(Set[443])).must_equal 8443
    end

    it "skips to 8444 when 443 and 8443 are taken" do
      _(ts.find_available_serve_port(Set[443, 8443])).must_equal 8444
    end

    it "goes beyond preferred list when all are taken" do
      all = Set[443, 8443, 8444, 8445, 8446, 8447, 8448, 8449, 8450]
      _(ts.find_available_serve_port(all)).must_equal 8451
    end

    it "returns 443 for funnel when nothing is in use" do
      _(ts.find_available_serve_port(Set.new, "funnel")).must_equal 443
    end

    it "returns 8443 for funnel when 443 is taken" do
      _(ts.find_available_serve_port(Set[443], "funnel")).must_equal 8443
    end

    it "returns 10000 for funnel when 443 and 8443 are taken" do
      _(ts.find_available_serve_port(Set[443, 8443], "funnel")).must_equal 10_000
    end

    it "throws when all funnel ports are taken" do
      err = _ { ts.find_available_serve_port(Set[443, 8443, 10_000], "funnel") }.must_raise Portless::Error
      _(err.message).must_include "All Tailscale Funnel ports are in use"
    end
  end

  # -----------------------------------------------------------------------
  # registerServe / unregisterServe
  # -----------------------------------------------------------------------

  describe "registerServe" do
    it "calls tailscale serve with correct args" do
      calls = []
      runner = create_runner({ "serve --bg --yes --https=443 http://127.0.0.1:4123" => { status: 0 } }, calls)
      ts.register_serve(4123, 443, runner: runner)
      _(calls.length).must_equal 1
      _(calls[0]).must_equal [ "serve", "--bg", "--yes", "--https=443", "http://127.0.0.1:4123" ]
    end

    it "uses custom HTTPS port" do
      calls = []
      runner = create_runner({ "serve --bg --yes --https=8443 http://127.0.0.1:4456" => { status: 0 } }, calls)
      ts.register_serve(4456, 8443, runner: runner)
      _(calls[0]).must_include "--https=8443"
    end

    it "throws on conflict" do
      runner = create_runner({
                               "serve --bg --yes --https=443 http://127.0.0.1:4123" => {
                                 status: 1, stderr: "port already in use"
                               }
                             })
      err = _ { ts.register_serve(4123, 443, runner: runner) }.must_raise Portless::Error
      _(err.message).must_include "already in use"
    end

    it "throws on ENOENT" do
      enoent = Errno::ENOENT.new("spawn tailscale")
      runner = create_runner({
                               "serve --bg --yes --https=443 http://127.0.0.1:4123" => { status: nil, error: enoent }
                             })
      err = _ { ts.register_serve(4123, 443, runner: runner) }.must_raise Portless::Error
      _(err.message).must_include "Tailscale CLI not found"
    end

    it "throws generic error on non-conflict failure" do
      runner = create_runner({
                               "serve --bg --yes --https=443 http://127.0.0.1:4123" => {
                                 status: 1, stderr: "some unknown problem"
                               }
                             })
      err = _ { ts.register_serve(4123, 443, runner: runner) }.must_raise Portless::Error
      _(err.message).must_include "some unknown problem"
    end
  end

  describe "unregisterServe" do
    it "calls tailscale serve off with correct args" do
      calls = []
      runner = create_runner({ "serve --yes --https=443 off" => { status: 0 } }, calls)
      ts.unregister_serve(443, runner: runner)
      _(calls[0]).must_equal [ "serve", "--yes", "--https=443", "off" ]
    end

    it "ignores missing when requested" do
      runner = create_runner({ "serve --yes --https=443 off" => { status: 1, stderr: "nothing to remove" } })
      ts.unregister_serve(443, ignore_missing: true, runner: runner)
    end

    it "throws on unexpected failure" do
      runner = create_runner({ "serve --yes --https=443 off" => { status: 1, stderr: "permission denied" } })
      err = _ { ts.unregister_serve(443, runner: runner) }.must_raise Portless::Error
      _(err.message).must_include "permission denied"
    end

    it "silently returns on ENOENT" do
      enoent = Errno::ENOENT.new("spawn tailscale")
      runner = create_runner({ "serve --yes --https=443 off" => { status: nil, error: enoent } })
      ts.unregister_serve(443, runner: runner)
    end
  end

  # -----------------------------------------------------------------------
  # registerFunnel / unregisterFunnel
  # -----------------------------------------------------------------------

  describe "registerFunnel" do
    it "calls tailscale funnel with correct args" do
      calls = []
      runner = create_runner({ "funnel --bg --yes --https=443 http://127.0.0.1:4123" => { status: 0 } }, calls)
      ts.register_funnel(4123, 443, runner: runner)
      _(calls[0]).must_equal [ "funnel", "--bg", "--yes", "--https=443", "http://127.0.0.1:4123" ]
    end

    it "throws on conflict with funnel port info" do
      runner = create_runner({
                               "funnel --bg --yes --https=443 http://127.0.0.1:4123" => {
                                 status: 1, stderr: "port already in use"
                               }
                             })
      err = _ { ts.register_funnel(4123, 443, runner: runner) }.must_raise Portless::Error
      _(err.message).must_include "Tailscale Funnel supports ports 443, 8443, and 10000"
    end

    it "throws an actionable error when Funnel is not enabled on the tailnet" do
      runner = create_runner({
                               "funnel --bg --yes --https=443 http://127.0.0.1:4123" => {
                                 status: 1,
                                 stderr: [
                                   "Funnel is not enabled on your tailnet.",
                                   "To enable, visit:",
                                   "",
                                   "https://login.tailscale.com/f/funnel?node=nMNPgMjBts11CNTRL"
                                 ].join("\n")
                               }
                             })
      err = _ { ts.register_funnel(4123, 443, runner: runner) }.must_raise Portless::Error
      _(err.message).must_include "Tailscale Funnel is not enabled on your tailnet"
    end

    it "throws an actionable error when Funnel registration times out" do
      timeout = Errno::ETIMEDOUT.new("spawnSync tailscale")
      runner = create_runner({
                               "funnel --bg --yes --https=443 http://127.0.0.1:4123" => { status: nil, error: timeout }
                             })
      err = _ { ts.register_funnel(4123, 443, runner: runner) }.must_raise Portless::Error
      _(err.message).must_include "Tailscale Funnel registration timed out"
    end
  end

  describe "unregisterFunnel" do
    it "calls tailscale funnel off with correct args" do
      calls = []
      runner = create_runner({ "funnel --yes --https=443 off" => { status: 0 } }, calls)
      ts.unregister_funnel(443, runner: runner)
      _(calls[0]).must_equal [ "funnel", "--yes", "--https=443", "off" ]
    end

    it "ignores missing when requested" do
      runner = create_runner({ "funnel --yes --https=8443 off" => { status: 1, stderr: "does not exist" } })
      ts.unregister_funnel(8443, ignore_missing: true, runner: runner)
    end
  end

  # -----------------------------------------------------------------------
  # unregisterTailscale
  # -----------------------------------------------------------------------

  describe "unregisterTailscale" do
    it "calls serve off for non-funnel route" do
      calls = []
      runner = create_runner({ "serve --yes --https=443 off" => { status: 0 } }, calls)
      ts.unregister_serve(443, runner: runner)
      _(calls[0]).must_equal [ "serve", "--yes", "--https=443", "off" ]
    end

    it "calls funnel off for funnel route" do
      calls = []
      runner = create_runner({ "funnel --yes --https=8443 off" => { status: 0 } }, calls)
      ts.unregister_funnel(8443, runner: runner)
      _(calls[0]).must_equal [ "funnel", "--yes", "--https=8443", "off" ]
    end

    it "is a no-op when tailscaleHttpsPort is undefined" do
      _(ts.unregister_tailscale({})).must_be_nil
    end

    it "is a no-op when tailscaleHttpsPort is missing" do
      _(ts.unregister_tailscale({ tailscale_funnel: true })).must_be_nil
    end
  end

  # -----------------------------------------------------------------------
  # formatTailscaleUrl
  # -----------------------------------------------------------------------

  describe "findWindowsCmdShim" do
    it "returns an existing .cmd shim" do
      dir = Dir.mktmpdir("portless-tailscale-shim-")
      shim = File.join(dir, "tailscale.cmd")
      File.write(shim, "@echo off\r\n")
      begin
        _(ts.find_windows_cmd_shim("tailscale", { "PATH" => dir })).must_equal shim
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "returns null when no shim exists" do
      dir = Dir.mktmpdir("portless-tailscale-no-shim-")
      begin
        _(ts.find_windows_cmd_shim("tailscale", { "PATH" => dir })).must_be_nil
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe "formatTailscaleUrl" do
    it "omits port for 443" do
      _(ts.format_tailscale_url("https://devbox.example.ts.net", 443)).must_equal "https://devbox.example.ts.net"
    end

    it "includes non-default port" do
      _(ts.format_tailscale_url("https://devbox.example.ts.net", 8443)).must_equal "https://devbox.example.ts.net:8443"
    end

    it "trims trailing slash from base URL" do
      _(ts.format_tailscale_url("https://devbox.example.ts.net/", 443)).must_equal "https://devbox.example.ts.net"
    end
  end
end
