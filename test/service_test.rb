# frozen_string_literal: true

require "test_helper"

# Ported from service.test.ts (spec building + install-flag parsing).
class ServiceTest < Minitest::Test
  S = Portless::Service
  ENTRY = [ "/usr/bin/ruby", "-I", "/gem/lib", "/gem/exe/rb-portless" ].freeze

  def parse(*args, env: {}) = S.parse_install_config([ "service", "install", *args ], env)

  def spec(platform, config = {}) = S.build_spec(platform: platform, entry_argv: ENTRY, user_home: "/Users/dev",
                                                 uid: "501", gid: "20", install_config: config)

  def test_defaults
    c = parse
    assert_equal 443, c[:proxy_port]
    assert c[:use_https]
    assert_equal [ "localhost" ], c[:tlds]
  end

  def test_flags
    c = parse("--no-tls", "--tld", "test", "--tld=dev.example.com", "--wildcard", "--state-dir", "~/s")
    assert_equal 80, c[:proxy_port]
    refute c[:use_https]
    assert_equal %w[test dev.example.com], c[:tlds]
    assert c[:use_wildcard]
    c = parse("--ip", "10.0.0.5", "--tld", "test")
    assert c[:lan_mode]
    assert c[:lan_ip_explicit]
    assert_equal [ "local" ], c[:tlds]
    assert_equal 8443, parse("-p", "8443")[:proxy_port]
    assert_equal 80, parse("--unprivileged")[:proxy_port]
    assert_equal 443, parse("--unprivileged", "--https")[:proxy_port]
    assert parse("--cert", "c.pem", "--key", "k.pem")[:use_https]
  end

  def test_env
    c = parse(env: { "PORTLESS_HTTPS" => "0", "PORTLESS_TLD" => "a,b", "PORTLESS_SYNC_HOSTS" => "0",
                     "PORTLESS_PORT" => "1355" })
    refute c[:use_https]
    assert_equal %w[a b], c[:tlds]
    assert_equal 1355, c[:proxy_port]
    assert_equal({ "PORTLESS_SYNC_HOSTS" => "0" }, c[:extra_env])
  end

  def test_usage_errors
    assert_raises(Portless::UsageError) { parse("--cert", "c.pem") }
    assert_raises(Portless::UsageError) { parse("--bogus") }
    assert_raises(Portless::UsageError) { parse("-p", "70000") }
    assert_raises(Portless::UsageError) { parse("--https=1") }
    assert_raises(Portless::UsageError) { parse("extra") }
    assert_raises(Portless::UsageError) { S.handle(%w[service frobnicate]) }
  end

  def test_launchd_plist_carries_flags_and_env
    s = spec("darwin", parse("--tld", "test", "--wildcard"))
    assert_equal "/Library/LaunchDaemons/rb.portless.proxy.plist", s[:plist_path]
    assert_equal [ *ENTRY, "proxy", "start", "--foreground", "--port", "443", "--https", "--tld", "test", "--wildcard",
                   "--skip-trust" ], s[:program_arguments]
    assert_includes s[:plist], "<key>PORTLESS_TLD</key>\n    <string>test</string>"
    assert_includes s[:plist], "<key>PORTLESS_WILDCARD</key>\n    <string>1</string>"
    assert_includes s[:plist], "<key>SUDO_UID</key>\n    <string>501</string>"
    assert_includes s[:plist], "<string>/Users/dev/.rb-portless/service.log</string>"
  end

  def test_systemd_unit
    s = spec("linux", parse("--lan", "--ip", "10.0.0.5"))
    assert_equal "/etc/systemd/system/rb-portless.service", s[:unit_path]
    assert_includes s[:unit], 'Environment=PORTLESS_LAN_IP="10.0.0.5"'
    assert_includes s[:unit], 'Environment=PORTLESS_TLD="local"'
    assert_includes s[:unit], '"--lan" "--ip" "10.0.0.5"'
    assert_includes s[:unit], "Restart=on-failure"
  end

  def test_installed_config_round_trips
    s = spec("linux", parse("-p", "8443", "--tld", "test", "--unprivileged", "--https"))
    words = S.parse_quoted_words(s[:unit][/^ExecStart=(.*)$/, 1])
    env = s[:unit].scan(/^Environment=(\w+)=(.*)$/).to_h { |k, v| [ k, S.parse_quoted_words(v).first ] }
    config = S.installed_config_from_snapshot({ command: words, env: env }, s[:config])
    assert_equal 8443, config[:proxy_port]
    assert_equal [ "test" ], config[:tlds]
    assert config[:unprivileged]
    assert config[:use_https]
    assert_equal "/Users/dev/.rb-portless", config[:state_dir]
  end

  def test_install_keywords_map_to_flags
    seen = nil
    S.stub(:install_from_args, ->(args) { seen = args }) do
      S.install(port: 8443, no_tls: true, tlds: %w[a b], wildcard: true, state_dir: "/s")
    end
    assert_equal %w[service install --port 8443 --no-tls --tld a --tld b --wildcard --state-dir /s], seen
  end

  def test_parse_quoted_words
    assert_equal [ "a b", 'c"d', "e\\f" ], S.parse_quoted_words('"a b" "c\\"d" e\\\\f')
  end

  def test_uninstall_sudo_args
    args = S.uninstall_sudo_args(home: "/Users/dev", env: { "PORTLESS_TLD" => "test", "PORTLESS_STATE_DIR" => "/x" })
    assert_equal [ "env", "PORTLESS_TLD=test", "HOME=/Users/dev", "PORTLESS_STATE_DIR=/x" ], args.first(4)
    assert_equal %w[service uninstall], args.last(2)
  end
end

class ServiceBareHelpTest < Minitest::Test
  def test_bare_service_prints_the_same_help_as_service_help
    bare, = capture_io { Portless::Service.print_help }
    flag, = capture_io { Object.new.extend(Portless::Help).print_service_help }
    assert_equal flag, bare
    assert_includes bare, "Windows installs a Task Scheduler startup task that runs as SYSTEM.\n\n"
  end
end
