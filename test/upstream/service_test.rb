# frozen_string_literal: true

require_relative "../test_helper"
require "minitest/mock"

# Mirror of packages/portless/src/service.test.ts
#
# Like upstream's vi.mock of node:fs, certs, ensureStateDir and mDNS, every
# test runs with Service's file writes/removals, cert generation, CA trust and
# the state-dir check stubbed out, and every command goes to a fake runner:
# nothing is ever installed, written under /Library or /etc, or trusted.

module ServiceMirror
  # Records what the stubbed fs/state calls received (upstream's vi.fn mocks).
  class Calls
    attr_reader :writes, :rms, :ensure_state_dir

    def initialize
      @writes = []
      @rms = []
      @ensure_state_dir = []
    end
  end

  # setPlatform / setGetuid / vi.mocked(...) overrides, then the module-level
  # mocks that every test gets.
  def with_service_mocks(platform: nil, uid: nil, exists: nil, read: nil, rm: nil, ensure_state_dir: nil,
                         discover_state: nil, proxy_running: nil, &block)
    calls = Calls.new
    stubs = [
      [ Portless::Service, :write_file, ->(path, content) { calls.writes << [ path, content ] } ],
      [ Portless::Service, :chmod_file, ->(*_args) { nil } ],
      [ Portless::Service, :rm_file, lambda { |path|
        calls.rms << path
        rm&.call(path)
      } ],
      [ Portless::State, :ensure_state_dir, lambda { |dir|
        calls.ensure_state_dir << dir
        ensure_state_dir&.call(dir)
      } ],
      [ Portless::Certs, :ensure_certs, ->(*_args) { { cert_path: "/fake/server.pem", key_path: "/fake/server-key.pem" } } ],
      [ Portless::Trust, :trusted?, ->(*_args) { true } ],
      [ Portless::Trust, :trust_ca, ->(*_args) { { trusted: true } } ],
      [ Portless::Mdns, :supported, ->(*_args, **_kw) { { supported: true } } ]
    ]
    stubs << [ Portless::Privilege, :host_platform, ->(*_args) { platform } ] if platform
    stubs << [ Portless::Privilege, :root?, ->(*_args) { uid.zero? } ] if uid
    stubs << [ Portless::Service, :file_exist?, exists ] if exists
    stubs << [ Portless::Service, :read_file, read ] if read
    stubs << [ Portless::Daemon, :discover_state, discover_state ] if discover_state
    stubs << [ Portless::Health, :proxy_running?, proxy_running ] if proxy_running
    nest_stubs(stubs) { block.call(calls) }
  end

  def nest_stubs(stubs, &block)
    return block.call if stubs.empty?

    obj, name, value = stubs.first
    obj.stub(name, value) { nest_stubs(stubs.drop(1), &block) }
  end

  # vi.fn runner: records [command, args] and answers with the block's result.
  def mock_runner(&impl)
    calls = []
    runner = lambda do |command, args, **_opts|
      calls << [ command, args ]
      impl.call(command, args)
    end
    [ runner, calls ]
  end

  def with_env(vars)
    saved = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def must_match_object(actual, expected)
    expected.each { |key, value| _(actual[key]).must_equal value, key.to_s }
  end

  def node_path = RbConfig.ruby
end

describe "buildServiceSpec" do
  include ServiceMirror

  it "builds a macOS LaunchDaemon for the HTTPS proxy" do
    spec = Portless::Service.build_service_spec(
      platform: "darwin",
      node_path: "/usr/local/bin/node",
      entry_script: "/usr/local/lib/node_modules/portless/dist/cli.js",
      user_home: "/Users/alice",
      uid: "501",
      gid: "20"
    )

    _(spec[:platform]).must_equal "darwin"
    _(spec[:plist_path]).must_equal "/Library/LaunchDaemons/rb.portless.proxy.plist"
    _(spec[:program_arguments]).must_equal [
      "/usr/local/bin/node",
      "/usr/local/lib/node_modules/portless/dist/cli.js",
      "proxy",
      "start",
      "--foreground",
      "--port",
      "443",
      "--https",
      "--skip-trust"
    ]
    _(spec[:plist]).must_include "<key>RunAtLoad</key>"
    _(spec[:plist]).must_include "<key>KeepAlive</key>"
    _(spec[:plist]).must_include "<key>PORTLESS_STATE_DIR</key>"
    _(spec[:plist]).must_include "<string>/Users/alice/.rb-portless</string>"
    _(spec[:plist]).must_include "<key>SUDO_UID</key>"
    _(spec[:plist]).must_include "<string>501</string>"
  end

  it "builds a Linux systemd unit for the HTTPS proxy" do
    spec = Portless::Service.build_service_spec(
      platform: "linux",
      node_path: "/usr/bin/node",
      entry_script: "/usr/lib/node_modules/portless/dist/cli.js",
      user_home: "/home/alice",
      uid: "1000",
      gid: "1000"
    )

    _(spec[:platform]).must_equal "linux"
    _(spec[:unit_path]).must_equal "/etc/systemd/system/rb-portless.service"
    _(spec[:exec_start]).must_equal [
      "/usr/bin/node",
      "/usr/lib/node_modules/portless/dist/cli.js",
      "proxy",
      "start",
      "--foreground",
      "--port",
      "443",
      "--https",
      "--skip-trust"
    ]
    _(spec[:unit]).must_include "Description=rb-portless HTTPS proxy"
    _(spec[:unit]).must_include 'Environment=PORTLESS_STATE_DIR="/home/alice/.rb-portless"'
    _(spec[:unit]).must_include 'Environment=SUDO_UID="1000"'
    _(spec[:unit]).must_include(
      'ExecStart="/usr/bin/node" "/usr/lib/node_modules/portless/dist/cli.js" "proxy" "start" "--foreground" "--port" "443" "--https" "--skip-trust"'
    )
    _(spec[:unit]).must_include "WantedBy=multi-user.target"
  end

  it "uses unconditional KeepAlive in the macOS plist" do
    spec = Portless::Service.build_service_spec(
      platform: "darwin",
      node_path: "/usr/local/bin/node",
      entry_script: "/usr/local/lib/portless/cli.js",
      user_home: "/Users/bob",
      uid: "501",
      gid: "20"
    )

    _(spec[:plist]).must_include "<key>KeepAlive</key>\n  <true/>"
    _(spec[:plist]).wont_include "SuccessfulExit"
  end

  it "persists LAN and wildcard settings in a macOS LaunchDaemon" do
    spec = Portless::Service.build_service_spec(
      platform: "darwin",
      node_path: "/usr/local/bin/node",
      entry_script: "/usr/local/lib/portless/cli.js",
      user_home: "/Users/alice",
      uid: "501",
      gid: "20",
      install_config: {
        proxy_port: 8443,
        lan_mode: true,
        lan_ip: "192.168.1.42",
        lan_ip_explicit: true,
        use_wildcard: true
      }
    )

    _(spec[:program_arguments]).must_include "--lan"
    _(spec[:program_arguments]).must_include "--ip"
    _(spec[:program_arguments]).must_include "192.168.1.42"
    _(spec[:program_arguments]).must_include "--wildcard"
    _(spec[:program_arguments]).must_include "8443"
    _(spec[:plist]).must_include "<key>PORTLESS_LAN</key>"
    _(spec[:plist]).must_include "<string>1</string>"
    _(spec[:plist]).must_include "<key>PORTLESS_LAN_IP</key>"
    _(spec[:plist]).must_include "<string>192.168.1.42</string>"
    _(spec[:plist]).must_include "<key>PORTLESS_WILDCARD</key>"
  end

  it "defaults an unprivileged service to plain HTTP on port 80" do
    config = Portless::Service.parse_service_install_config([ "service", "install", "--unprivileged" ], {})
    must_match_object(config, { unprivileged: true, use_https: false, proxy_port: 80 })
  end

  it "accepts --flag=value for install options" do
    config = Portless::Service.parse_service_install_config(
      [ "service", "install", "--port=8443", "--tld=mydb" ],
      {}
    )
    must_match_object(config, { proxy_port: 8443, tld: "mydb" })
  end

  it "lets the last TLS option decide HTTPS" do
    _(
      Portless::Service.parse_service_install_config([ "service", "install", "--no-tls", "--https" ], {})[:use_https]
    ).must_equal true
    _(
      Portless::Service.parse_service_install_config([ "service", "install", "--https", "--no-tls" ], {})[:use_https]
    ).must_equal false

    cert_then_no_tls = Portless::Service.parse_service_install_config(
      [ "service", "install", "--cert", "a.pem", "--key", "b.pem", "--no-tls" ],
      {}
    )
    _(cert_then_no_tls[:use_https]).must_equal false
    _(cert_then_no_tls[:custom_cert_path]).must_equal "a.pem"

    no_tls_then_cert = Portless::Service.parse_service_install_config(
      [ "service", "install", "--no-tls", "--cert", "a.pem", "--key", "b.pem" ],
      {}
    )
    _(no_tls_then_cert[:use_https]).must_equal true
  end

  it "keeps the last value of a repeated scalar flag" do
    _(
      Portless::Service.parse_service_install_config([ "service", "install", "--port", "1000", "-p", "2000" ], {})[:proxy_port]
    ).must_equal 2000
    _(
      Portless::Service.parse_service_install_config([ "service", "install", "-p", "1000", "--port=2000" ], {})[:proxy_port]
    ).must_equal 2000
    _(
      Portless::Service.parse_service_install_config(
        [ "service", "install", "--ip", "10.0.0.1", "--ip", "10.0.0.2" ], {}
      )[:lan_ip]
    ).must_equal "10.0.0.2"
    _(
      Portless::Service.parse_service_install_config(
        [ "service", "install", "--state-dir", "/one", "--state-dir", "/two" ],
        {}
      )[:state_dir]
    ).must_equal "/two"
  end

  it "accumulates repeated --tld flags in order" do
    config = Portless::Service.parse_service_install_config(
      [ "service", "install", "--tld=one", "--tld", "two" ],
      {}
    )
    _(config[:tlds]).must_equal [ "one", "two" ]
    _(config[:tld]).must_equal "one"
  end

  it "rejects an invalid --port value as a usage error" do
    err = _ { Portless::Service.parse_service_install_config([ "service", "install", "--port=abc" ], {}) }
          .must_raise Portless::UsageError
    _(err.message).must_include "Invalid port number: abc"
  end

  it "rejects a value given to a boolean install flag" do
    err = _ { Portless::Service.parse_service_install_config([ "service", "install", "--https=1" ], {}) }
          .must_raise Portless::UsageError
    _(err.message).must_include "--https does not take a value."
  end

  it "rejects an invalid --tld value as a usage error" do
    _ { Portless::Service.parse_service_install_config([ "service", "install", "--tld=_bad" ], {}) }
      .must_raise Portless::UsageError
  end

  it "keeps HTTPS for an unprivileged service when asked: %j %j" do
    [
      [ [ "--unprivileged", "--https" ], {} ],
      [ [ "--unprivileged" ], { "PORTLESS_HTTPS" => "1" } ]
    ].each do |flags, env|
      config = Portless::Service.parse_service_install_config([ "service", "install", *flags ], env)
      must_match_object(config, { unprivileged: true, use_https: true, proxy_port: 443 })
    end
  end

  it "persists unprivileged mode in a Linux service" do
    spec = Portless::Service.build_service_spec(
      platform: "linux",
      node_path: "/usr/bin/node",
      entry_script: "/usr/lib/node_modules/portless/dist/cli.js",
      user_home: "/home/alice",
      uid: "1000",
      gid: "1000",
      install_config: { proxy_port: 80, use_https: false, unprivileged: true }
    )

    _(spec[:exec_start]).must_include "--unprivileged"
    _(spec[:unit]).must_include 'Environment=PORTLESS_UNPRIVILEGED="1"'
  end

  it "persists no-TLS, custom TLD, and custom state in a Linux service" do
    spec = Portless::Service.build_service_spec(
      platform: "linux",
      node_path: "/usr/bin/node",
      entry_script: "/usr/lib/node_modules/portless/dist/cli.js",
      user_home: "/home/alice",
      uid: "1000",
      gid: "1000",
      install_config: {
        state_dir: "/srv/portless",
        proxy_port: 8080,
        use_https: false,
        tld: "test",
        use_wildcard: true
      }
    )

    _(spec[:exec_start]).must_include "--no-tls"
    _(spec[:exec_start]).must_include "--tld"
    _(spec[:exec_start]).must_include "test"
    _(spec[:exec_start]).must_include "--wildcard"
    _(spec[:unit]).must_include 'Environment=PORTLESS_STATE_DIR="/srv/portless"'
    _(spec[:unit]).must_include 'Environment=PORTLESS_PORT="8080"'
    _(spec[:unit]).must_include 'Environment=PORTLESS_HTTPS="0"'
    _(spec[:unit]).must_include 'Environment=PORTLESS_TLD="test"'
    _(spec[:state_dir]).must_equal "/srv/portless"
  end
end

describe "buildServiceUninstallSudoArgs" do
  it "builds a service-scoped sudo command that preserves user state" do
    args = Portless::Service.build_service_uninstall_sudo_args(
      "/fake/cli.js",
      node_path: "/usr/bin/node",
      home: "/Users/alice",
      env: {
        "PORTLESS_STATE_DIR" => "/Users/alice/.portless",
        "PORTLESS_DEBUG" => "1",
        "OTHER_ENV" => "ignored"
      }
    )

    _(args).must_equal [
      "env",
      "PORTLESS_DEBUG=1",
      "HOME=/Users/alice",
      "PORTLESS_STATE_DIR=/Users/alice/.portless",
      "/usr/bin/node",
      "/fake/cli.js",
      "service",
      "uninstall"
    ]
    _(args).wont_include "clean"
  end
end

describe "unloaded macOS service removal" do
  include ServiceMirror

  it "removes the plist during %s" do
    [ "clean", "uninstall" ].each do |command|
      with_service_mocks(platform: "darwin", uid: 0, exists: ->(_file) { true }) do |calls|
        runner, runner_calls = mock_runner do |_cmd, args|
          {
            status: args.length == 2 ? 3 : 5,
            stdout: "",
            stderr: args.length == 2 ? "Boot-out failed: 3: No such process" : "Boot-out failed: 5: Input/output error"
          }
        end
        if command == "clean"
          _(Portless::Service.try_uninstall_service("/fake/cli.js", runner)).must_equal(
            { removed: true, installed: true }
          )
        else
          out, = capture_io do
            Portless::Service.handle_service([ "service", "uninstall" ], entry_script: "/fake/cli.js", runner: runner)
          end
          _(out).must_include "uninstalled"
        end
        _(runner_calls).must_include [ "launchctl", [ "bootout", "system/rb.portless.proxy" ] ]
        _(calls.rms).must_include "/Library/LaunchDaemons/rb.portless.proxy.plist"
      end
    end
  end
end

describe "tryUninstallService" do
  include ServiceMirror

  it "returns removed: false when service is not installed" do
    with_service_mocks(exists: ->(_file) { false }) do
      runner = ->(*_args, **_opts) { { status: 1, stdout: "", stderr: "" } }
      result = Portless::Service.try_uninstall_service("/fake/cli.js", runner)
      _(result[:removed]).must_equal false
      _(result[:installed]).must_equal false
    end
  end

  it "returns removed: false when runner throws" do
    with_service_mocks(platform: "linux", exists: ->(_file) { true }) do
      runner = ->(*_args, **_opts) { raise "spawn failed" }
      result = Portless::Service.try_uninstall_service("/fake/cli.js", runner)
      _(result[:removed]).must_equal false
      _(result[:installed]).must_equal true
      _(result[:error]).must_include "spawn failed"
    end
  end

  it "marks installed services that need elevation" do
    rm = ->(_path) { raise Errno::EACCES, "permission denied" }
    with_service_mocks(platform: "linux", exists: ->(_file) { true }, rm: rm) do
      runner, = mock_runner { { status: 0, stdout: "", stderr: "" } }

      result = Portless::Service.try_uninstall_service("/fake/cli.js", runner)

      _(result[:removed]).must_equal false
      _(result[:installed]).must_equal true
      _(result[:needs_elevation]).must_equal true
    end
  end

  it "marks systemctl's interactive authentication failure as needing elevation" do
    with_service_mocks(platform: "linux", exists: ->(_file) { true }) do |calls|
      runner, = mock_runner do
        { status: 1, stdout: "", stderr: "Failed to disable unit: Interactive authentication required." }
      end

      result = Portless::Service.try_uninstall_service("/fake/cli.js", runner)

      _(result[:removed]).must_equal false
      _(result[:installed]).must_equal true
      _(result[:error]).must_include "Interactive authentication required"
      _(result[:needs_elevation]).must_equal true
      _(calls.rms).must_be_empty
    end
  end

  it "does not claim elevation when the removal runs as root" do
    with_service_mocks(platform: "linux", uid: 0, exists: ->(_file) { true }) do
      runner, = mock_runner { { status: 1, stdout: "", stderr: "Failed to disable unit: Unit file is masked." } }

      result = Portless::Service.try_uninstall_service("/fake/cli.js", runner)

      _(result[:removed]).must_equal false
      _(result[:needs_elevation]).must_equal false
    end
  end

  it "does not claim elevation when the service manager is missing" do
    with_service_mocks(platform: "linux", exists: ->(_file) { true }) do
      runner, = mock_runner { { status: nil, error: Errno::ENOENT.new("spawn systemctl") } }

      result = Portless::Service.try_uninstall_service("/fake/cli.js", runner)

      _(result[:removed]).must_equal false
      _(result[:needs_elevation]).must_equal false
    end
  end

  it "reports a failed launchctl bootout instead of claiming removal" do
    with_service_mocks(platform: "darwin", exists: ->(_file) { true }) do |calls|
      runner, = mock_runner { { status: 1, stdout: "", stderr: "Boot-out failed: 1: Operation not permitted" } }

      result = Portless::Service.try_uninstall_service("/fake/cli.js", runner)

      _(result[:removed]).must_equal false
      _(result[:installed]).must_equal true
      _(result[:error]).must_include "Operation not permitted"
      _(result[:needs_elevation]).must_equal true
      _(calls.rms).must_be_empty
    end
  end
end

describe "handleService" do
  include ServiceMirror

  it "prints help and exits 0 when no subcommand is given" do
    runner, = mock_runner { { status: 0, stdout: "", stderr: "" } }
    error = nil
    output, = capture_io do
      error = _ { Portless::Service.handle_service([ "service" ], entry_script: "/fake/cli.js", runner: runner) }
              .must_raise SystemExit
    end
    _(error.status).must_equal 0
    _(output).must_include "rb-portless service"
    _(output).must_include "service install"
    _(output).must_include "service uninstall"
    _(output).must_include "service status"
  end

  it "throws a usage error for an unknown subcommand" do
    runner, runner_calls = mock_runner { { status: 0, stdout: "", stderr: "" } }
    err = _ { Portless::Service.handle_service([ "service", "bogus" ], entry_script: "/fake/cli.js", runner: runner) }
          .must_raise Portless::UsageError
    _(err.message).must_include 'Unknown service command "bogus".'
    _(runner_calls).must_be_empty
  end

  it "stops an existing proxy before restarting the Linux service" do
    with_service_mocks(platform: "linux", uid: 0) do
      runner, runner_calls = mock_runner { { status: 0, stdout: "", stderr: "" } }

      capture_io do
        Portless::Service.handle_service([ "service", "install" ], entry_script: "/fake/cli.js", runner: runner)
      end

      stop_index = runner_calls.index do |command, args|
        command == node_path && args.join(" ") == "/fake/cli.js proxy stop --port 443"
      end
      restart_index = runner_calls.index do |command, args|
        command == "systemctl" && args.join(" ") == "restart rb-portless.service"
      end

      _(stop_index).wont_be_nil
      _(restart_index).must_be :>, stop_index
    end
  end

  it "uses install flags when stopping an existing proxy before restart" do
    with_service_mocks(platform: "linux", uid: 0) do
      runner, runner_calls = mock_runner { { status: 0, stdout: "", stderr: "" } }

      capture_io do
        Portless::Service.handle_service([ "service", "install", "--port", "8443", "--wildcard" ],
                                         entry_script: "/fake/cli.js", runner: runner)
      end

      _(runner_calls).must_include [ node_path, [ "/fake/cli.js", "proxy", "stop", "--port", "8443" ] ]
    end
  end

  it "stops the discovered proxy before a different install port" do
    current_port = 19_000
    target_port = 19_001
    discover = lambda do
      {
        dir: "/tmp/portless-service-current-test",
        port: current_port,
        tls: true,
        tld: "localhost",
        tlds: [ "localhost" ],
        lan_mode: false,
        lan_ip: nil
      }
    end
    with_service_mocks(platform: "linux", uid: 0, discover_state: discover,
                       proxy_running: ->(port, *_rest, **_kw) { port == current_port }) do
      runner, runner_calls = mock_runner { { status: 0, stdout: "", stderr: "" } }

      capture_io do
        Portless::Service.handle_service([ "service", "install", "--port", target_port.to_s ],
                                         entry_script: "/fake/cli.js", runner: runner)
      end

      stop_ports = runner_calls
                   .select { |command, args| command == node_path && args[0] == "/fake/cli.js" && args[1] == "proxy" && args[2] == "stop" }
                   .map { |_command, args| args[4] }
      _(stop_ports).must_equal [ current_port.to_s, target_port.to_s ]
    end
  end

  it "does not validate proxy env while uninstalling" do
    with_service_mocks(platform: "linux", uid: 0) do
      runner, runner_calls = mock_runner { { status: 0, stdout: "", stderr: "" } }

      with_env("PORTLESS_PORT" => "abc", "PORTLESS_TLD" => "bad-name") do
        capture_io do
          Portless::Service.handle_service([ "service", "uninstall" ], entry_script: "/fake/cli.js", runner: runner)
        end
      end

      _(runner_calls).must_include [ "systemctl", [ "disable", "--now", "rb-portless.service" ] ]
    end
  end

  it "fails the uninstall when the Linux service still cannot be disabled" do
    with_service_mocks(platform: "linux", uid: 0) do |calls|
      runner, = mock_runner { { status: 1, stdout: "", stderr: "Failed to disable unit: Access denied" } }

      output, = capture_io do
        err = _ do
          Portless::Service.handle_service([ "service", "uninstall" ], entry_script: "/fake/cli.js", runner: runner)
        end.must_raise Portless::Error
        _(err.message).must_include "Access denied"
      end

      _(calls.rms).must_be_empty
      _(output).wont_include "uninstalled"
    end
  end

  it "normalizes relative install paths before writing the Linux service" do
    with_service_mocks(platform: "linux", uid: 0) do |calls|
      runner, = mock_runner { { status: 0, stdout: "", stderr: "" } }

      capture_io do
        Portless::Service.handle_service(
          [
            "service",
            "install",
            "--state-dir",
            "relative-state",
            "--cert",
            "cert.pem",
            "--key",
            "key.pem"
          ],
          entry_script: "/fake/cli.js",
          runner: runner
        )
      end

      state_dir = File.expand_path("relative-state")
      cert_path = File.expand_path("cert.pem")
      key_path = File.expand_path("key.pem")
      systemd_state_dir = state_dir.gsub("\\", "\\\\\\\\")
      systemd_cert_path = cert_path.gsub("\\", "\\\\\\\\")
      systemd_key_path = key_path.gsub("\\", "\\\\\\\\")
      unit_write = calls.writes.find { |file, _| file == "/etc/systemd/system/rb-portless.service" }
      unit = unit_write&.last.to_s

      _(calls.ensure_state_dir).must_include state_dir
      _(unit).must_include "Environment=PORTLESS_STATE_DIR=\"#{systemd_state_dir}\""
      _(unit).must_include "\"--cert\" \"#{systemd_cert_path}\" \"--key\" \"#{systemd_key_path}\""
    end
  end

  it "refuses to install when another user controls the state directory" do
    with_service_mocks(platform: "linux", uid: 0, ensure_state_dir: ->(_dir) { "it is owned by another user" }) do |calls|
      runner, runner_calls = mock_runner { { status: 0, stdout: "", stderr: "" } }

      err = _ do
        Portless::Service.handle_service([ "service", "install", "--state-dir", "/shared/state" ],
                                         entry_script: "/fake/cli.js", runner: runner)
      end.must_raise Portless::Error
      _(err.message).must_include(
        "Cannot install the service with state in #{File.expand_path('/shared/state')}: it is owned by another user"
      )

      _(runner_calls).must_be_empty
      _(calls.writes).must_be_empty
    end
  end

  it "prints installed service config from a Linux unit" do
    installed_spec = Portless::Service.build_service_spec(
      platform: "linux",
      node_path: node_path,
      entry_script: "/fake/cli.js",
      user_home: "/home/alice",
      install_config: {
        state_dir: "/srv/portless",
        proxy_port: 8443,
        use_https: false,
        lan_mode: true,
        lan_ip: "192.168.1.42",
        lan_ip_explicit: true,
        use_wildcard: true
      }
    )

    with_service_mocks(platform: "linux", uid: 0,
                       exists: ->(file) { file == installed_spec[:unit_path] },
                       read: ->(file) { file == installed_spec[:unit_path] ? installed_spec[:unit] : "" }) do
      runner, = mock_runner do |command, args|
        if command == "systemctl" && args[0] == "is-enabled"
          { status: 0, stdout: "enabled\n", stderr: "" }
        elsif command == "systemctl" && args[0] == "is-active"
          { status: 1, stdout: "inactive\n", stderr: "" }
        else
          { status: 0, stdout: "", stderr: "" }
        end
      end

      output, = capture_io do
        Portless::Service.handle_service([ "service", "status" ], entry_script: "/fake/cli.js", runner: runner)
      end

      _(output).must_include "Proxy on 8443"
      _(output).must_include "HTTPS: no"
      _(output).must_include "TLDs: .local"
      _(output).must_include "LAN mode: yes"
      _(output).must_include "LAN IP: 192.168.1.42"
      _(output).must_include "Wildcard: yes"
      _(output).must_include "State directory: /srv/portless"
    end
  end
end
