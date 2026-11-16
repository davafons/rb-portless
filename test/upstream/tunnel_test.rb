# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/share"

# Mirror of packages/portless/src/tunnel.test.ts

describe "ngrok" do
  include UpstreamShare

  describe "ensureNgrokAvailable" do
    it "checks the ngrok CLI version" do
      calls = []
      runner = lambda do |args|
        calls << args
        { status: 0, stdout: "ngrok version 3.0.0", stderr: "" }
      end

      Portless::Tunnel.ensure_ngrok_available(runner)
      _(calls).must_equal [ [ "version" ] ]
    end

    it "throws an install hint when the ngrok CLI is missing" do
      error = Errno::ENOENT.new("spawn ngrok")
      runner = ->(_args) { { status: nil, stdout: "", stderr: "", error: error } }

      err = _ { Portless::Tunnel.ensure_ngrok_available(runner) }.must_raise Portless::Error
      _(err.message).must_include "ngrok CLI not found"
    end

    it "throws command output when the version check fails" do
      runner = ->(_args) { { status: 1, stdout: "", stderr: "permission denied" } }

      err = _ { Portless::Tunnel.ensure_ngrok_available(runner) }.must_raise Portless::Error
      _(err.message).must_include "permission denied"
    end
  end

  describe "buildNgrokArgs" do
    it "forwards HTTP traffic to the local app port with host rewriting" do
      _(Portless::Tunnel.build_ngrok_args(4123)).must_equal [
        "http",
        "--log=stdout",
        "--log-format=logfmt",
        "--host-header=rewrite",
        "http://127.0.0.1:4123"
      ]
    end

    it "uses the requested upstream host header" do
      _(Portless::Tunnel.build_ngrok_args(4123, "myapp.localhost")).must_equal [
        "http",
        "--log=stdout",
        "--log-format=logfmt",
        "--host-header=myapp.localhost",
        "http://127.0.0.1:4123"
      ]
    end
  end

  describe "extractNgrokUrl" do
    it "extracts the public URL from text output" do
      output = "Forwarding https://abc123.ngrok.app -> http://127.0.0.1:4123"
      _(Portless::Tunnel.extract_ngrok_url(output)).must_equal "https://abc123.ngrok.app"
    end

    it "extracts the public URL from structured log output" do
      output =
        't=2026-06-04 lvl=info msg="started tunnel" obj=tunnels url=https://abc123.ngrok-free.app'
      _(Portless::Tunnel.extract_ngrok_url(output)).must_equal "https://abc123.ngrok-free.app"
    end

    it "ignores ngrok docs URLs from errors" do
      output = "ERROR see https://ngrok.com/docs/errors/err_ngrok_4018"
      _(Portless::Tunnel.extract_ngrok_url(output)).must_be_nil
    end
  end

  describe "startNgrok" do
    it "spawns ngrok and resolves with the public URL" do
      child = UpstreamShare::MockNgrokChild.new
      calls = []
      child.write_stdout("Forwarding https://abc123.ngrok.app -> http://127.0.0.1:4123\n")
      started = Portless::Tunnel.start_ngrok(4123, spawner: create_spawner(child, calls), timeout: 1)

      _(started.url).must_equal "https://abc123.ngrok.app"
      _(started.pid).must_equal 12_345
      _(calls).must_equal [
        [
          "http",
          "--log=stdout",
          "--log-format=logfmt",
          "--host-header=rewrite",
          "http://127.0.0.1:4123"
        ]
      ]
    end

    it "notifies when ngrok exits after startup" do
      child = UpstreamShare::MockNgrokChild.new
      exits = []
      child.write_stdout("Forwarding https://abc123.ngrok.app -> http://127.0.0.1:4123\n")
      started = Portless::Tunnel.start_ngrok(4123, spawner: create_spawner(child), timeout: 1) do |code, signal|
        exits << { code: code, signal: signal }
      end

      _(started.url).must_equal "https://abc123.ngrok.app"
      child.emit_exit(0, nil)
      wait_until { exits.any? }
      _(exits).must_equal [ { code: 0, signal: nil } ]
    end

    it "throws an install hint when the ngrok CLI is missing" do
      error = Errno::ENOENT.new("spawn ngrok")
      spawner = ->(_args) { raise error }

      err = _ { Portless::Tunnel.start_ngrok(4123, spawner: spawner) }.must_raise Portless::Error
      _(err.message).must_include "ngrok CLI not found"
    end

    it "throws an auth hint when ngrok exits with auth output" do
      child = UpstreamShare::MockNgrokChild.new
      child.write_stderr("ERROR authtoken is required\n")
      child.emit_exit(1, nil)

      err = _ { Portless::Tunnel.start_ngrok(4123, spawner: create_spawner(child), timeout: 1) }
            .must_raise Portless::Error
      _(err.message).must_include "authentication is not configured"
    end

    it "kills ngrok when no public URL appears before the timeout" do
      child = UpstreamShare::MockNgrokChild.new

      err = _ { Portless::Tunnel.start_ngrok(4123, spawner: create_spawner(child), timeout: 0.001) }
            .must_raise Portless::Error
      _(err.message).must_include "Timed out waiting for ngrok"
      _(child.killed_with).must_equal "SIGTERM"
      child.emit_exit(nil, "SIGTERM")
    end
  end

  describe "stopNgrokProcess" do
    it "terminates the child process" do
      child = UpstreamShare::MockNgrokChild.new
      Portless::Tunnel.stop_ngrok_process(child)
      _(child.killed_with).must_equal "SIGTERM"
    end
  end
end

describe "cloudflare" do
  include UpstreamShare

  let(:banner) do
    "INF Thank you for trying Cloudflare Tunnel.\nINF |  https://red-fox-ab.trycloudflare.com  |\n"
  end
  let(:registered) { "INF Registered tunnel connection connIndex=0 protocol=quic\n" }
  let(:quick_url) { "https://red-fox-ab.trycloudflare.com" }

  let(:config_dir) { Dir.mktmpdir("portless-cf-") }
  let(:config_path) { "#{config_dir}/c.yml" }
  after { FileUtils.rm_rf(config_dir) }

  it "builds a quick tunnel command that ignores the user config" do
    _(Portless::Cloudflare.build_args(4123, "myapp.localhost", "/c.yml").join(" ")).must_equal(
      "tunnel --no-autoupdate --grace-period 1s --config /c.yml --url http://127.0.0.1:4123 --http-host-header myapp.localhost"
    )
  end

  it "reports the URL only once a connection is registered" do
    _(Portless::Cloudflare.extract_url(banner)).must_be_nil
    _(Portless::Cloudflare.extract_url(banner + registered)).must_equal quick_url
    _(Portless::Cloudflare.extract_url("https://api.trycloudflare.com\n#{registered}")).must_be_nil
    _(Portless::Cloudflare.extract_url("#{banner}INF Connection 4b2f-9a7b registered\n")).must_equal quick_url
  end

  it "writes an empty config and resolves once connected" do
    child = UpstreamShare::MockNgrokChild.new
    spawner = lambda do |args|
      _(File.read(config_path)).must_equal "{}"
      child.write_stderr(banner + registered)
      create_spawner(child).call(args)
    end
    started = Portless::Cloudflare.start(4123, config_path: config_path, spawner: spawner)
    _(started.url).must_equal quick_url
    _(started.pid).must_equal 12_345
  end

  it "reports ERR lines, or a generic message, when cloudflared exits early" do
    fail = lambda do |output|
      child = UpstreamShare::MockNgrokChild.new
      child.write_stderr(output)
      child.emit_exit(1, nil)
      Portless::Cloudflare.start(4123, config_path: config_path, spawner: create_spawner(child))
    rescue Portless::Error => e
      e.message
    end
    _(fail.call("#{banner}2026-10-16T12:00:01Z ERR failed to request quick Tunnel\n")).must_equal(
      "Failed to start Cloudflare tunnel: 2026-10-16T12:00:01Z ERR failed to request quick Tunnel (exit 1)"
    )
    _(fail.call(banner)).must_equal(
      "Failed to start Cloudflare tunnel: cloudflared exited before connecting (exit 1)"
    )
  end
end
