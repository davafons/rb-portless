# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "json"

class DoctorTest < Minitest::Test
  def setup
    @env = ENV.to_h
    @dir = Dir.mktmpdir("rb-portless-doctor")
    ENV["PORTLESS_STATE_DIR"] = @dir
    %w[PORTLESS_HTTPS PORTLESS_TLD PORTLESS_LAN].each { |k| ENV.delete(k) }
  end

  def teardown
    ENV.replace(@env)
    FileUtils.rm_rf(@dir)
  end

  def doctor(json: true)
    probes = []
    out = nil
    Portless::Health.stub(:proxy_running?, ->(port, tls = false) { probes << [ port, tls ]; false }) do
      Portless::PortOwner.stub(:port_listening?, false) do
        out, = capture_io { Portless::Doctor.new(json: json).run }
      end
    end
    [ out, probes ]
  end

  def test_invalid_portless_port_falls_back_to_the_protocol_port
    ENV["PORTLESS_PORT"] = "99999"
    out, = doctor
    assert_equal "https://127.0.0.1", JSON.parse(out)["proxyTarget"]
  end

  def test_probes_with_the_recorded_tls_mode
    File.write(File.join(@dir, "proxy.port"), "8443")
    File.write(File.join(@dir, "proxy.tls"), "1")
    _, probes = doctor
    assert_includes probes, [ 8443, true ]
  end
end
