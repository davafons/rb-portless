# frozen_string_literal: true

require_relative "test_helper"

class SmokeTest < Minitest::Test
  def test_version_present
    assert_match(/\A\d+\.\d+\.\d+/, Portless::VERSION)
  end

  def test_free_port_in_range_and_bindable
    port = Portless::FreePort.find
    assert_includes(Portless::Constants::MIN_APP_PORT..Portless::Constants::MAX_APP_PORT, port)
    refute_includes Portless::Constants::BLOCKED_PORTS, port
  end
end
