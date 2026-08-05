# frozen_string_literal: true

require_relative "test_helper"

# The PORTLESS_* env contract (overrides beat portless.json) and Config.load's
# on-disk behavior.
class ConfigEnvTest < Minitest::Test
  def with_env(env)
    previous = env.keys.to_h { |k| [ k, ENV[k] ] }
    ENV.update(env)
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def test_portless_https_forces_tls_off_and_on
    with_env("PORTLESS_HTTPS" => "0") do
      assert_equal false, Portless::Config.new({ "tls" => true }, Dir.pwd).tls
    end
    with_env("PORTLESS_HTTPS" => "true") do
      assert_equal true, Portless::Config.new({ "tls" => false }, Dir.pwd).tls
    end
  end

  def test_portless_tld_overrides_the_config_tld
    with_env("PORTLESS_TLD" => "myapp.test") do
      assert_equal "myapp.test", Portless::Config.new({ "tld" => "other.localhost" }, Dir.pwd).tld
    end
  end

  def test_env_run_options_seed_the_flag_defaults
    env = { "PORTLESS_LAN" => "1", "PORTLESS_NGROK" => "true",
            "PORTLESS_TAILSCALE" => "1", "PORTLESS_FUNNEL" => "1", "PORTLESS_APP_PORT" => "4555" }
    with_env(env) do
      options = Portless::CLI.new([]).send(:env_run_options)
      assert_equal({ lan: true, ngrok: true, tailscale: true, funnel: true, app_port: 4555 }, options)
    end
    assert_empty Portless::CLI.new([]).send(:env_run_options)
  end

  def test_load_reads_portless_json_from_disk
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "portless.json"),
                 JSON.generate({ "name" => "disk", "tld" => "disk.localhost", "appPort" => 4777, "tls" => false }))
      config = Portless::Config.load(dir)
      assert_equal "disk", config.name
      assert_equal "disk.localhost", config.hostname
      assert_equal 4777, config.app_port
      assert_equal false, config.tls
    end
  end

  def test_load_raises_a_clean_error_on_invalid_json
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "portless.json"), "{ not json")
      error = assert_raises(Portless::Error) { Portless::Config.load(dir) }
      assert_match(/invalid portless\.json/, error.message)
    end
  end
end
