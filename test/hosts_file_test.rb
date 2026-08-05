# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"

# Full sync/clean against a real file via the PORTLESS_HOSTS_FILE seam
# (smoke_test covers the pure block builders).
class HostsFileTest < Minitest::Test
  def setup
    @file = Tempfile.create("hosts")
    @file.write("127.0.0.1\tlocalhost\n::1\tlocalhost\n")
    @file.flush
    ENV["PORTLESS_HOSTS_FILE"] = @file.path
  end

  def teardown
    ENV.delete("PORTLESS_HOSTS_FILE")
    File.delete(@file.path) if File.exist?(@file.path)
  end

  def test_sync_is_idempotent_and_replaces_the_block
    Portless::Hosts.sync(%w[a.localhost b.localhost])
    Portless::Hosts.sync(%w[a.localhost b.localhost]) # second run must not duplicate
    content = File.read(@file.path)
    assert_equal 1, content.scan(Portless::Constants::HOSTS_BEGIN).size
    assert_includes content, "127.0.0.1\ta.localhost"
    assert_includes content, "::1\tlocalhost" # pre-existing entries untouched

    Portless::Hosts.sync(%w[c.localhost]) # replace, not merge
    content = File.read(@file.path)
    refute_includes content, "a.localhost"
    assert_includes content, "127.0.0.1\tc.localhost"
  end

  def test_clean_removes_only_the_managed_block
    Portless::Hosts.sync(%w[a.localhost])
    Portless::Hosts.clean
    content = File.read(@file.path)
    refute_includes content, Portless::Constants::HOSTS_BEGIN
    refute_includes content, "a.localhost"
    assert_includes content, "127.0.0.1\tlocalhost"
  end

  def test_unwritable_file_raises_a_clean_error
    File.chmod(0o444, @file.path)
    error = assert_raises(Portless::Error) { Portless::Hosts.sync(%w[a.localhost]) }
    assert_match(/needs root/, error.message)
  ensure
    File.chmod(0o644, @file.path)
  end
end
