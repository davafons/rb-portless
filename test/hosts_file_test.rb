# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"

# Ported from upstream hosts.test.ts, against a temp file via the hosts_path seam.
class HostsFileTest < Minitest::Test
  H = Portless::Hosts
  START = Portless::Constants::HOSTS_BEGIN
  FINISH = Portless::Constants::HOSTS_END

  def setup
    @file = Tempfile.create("hosts")
    @file.write("127.0.0.1\tlocalhost\n::1\tlocalhost\n")
    @file.flush
    H.hosts_path = @file.path
  end

  def teardown
    H.hosts_path = nil
    File.delete(@file.path) if File.exist?(@file.path)
  end

  def content = File.read(@file.path)

  def test_build_and_extract_block
    block = H.build_block(%w[a.localhost b.localhost])
    assert_equal "#{START}\n127.0.0.1 a.localhost\n127.0.0.1 b.localhost\n#{FINISH}", block
    assert_equal "", H.build_block([])
    assert_equal [ "127.0.0.1 a.localhost", "127.0.0.1 b.localhost" ], H.extract_managed_block("x\n#{block}\ny")
    assert_equal [], H.extract_managed_block("#{FINISH}\n#{START}")
  end

  def test_remove_block_normalizes_newlines
    text = "a\n\n\n#{H.build_block(%w[x.localhost])}\n\n\nb\n"
    assert_equal "a\n\nb\n", H.remove_block(text)
    assert_equal "plain", H.remove_block("plain")
  end

  def test_block_matches_exactly
    text = H.build_block(%w[a.localhost b.localhost])
    assert H.block_matches_hostnames?(text, %w[b.localhost a.localhost])
    refute H.block_matches_hostnames?(text, %w[a.localhost])
    refute H.block_matches_hostnames?(text, %w[a.localhost a.localhost b.localhost])
    refute H.block_matches_hostnames?("#{START}\n10.0.0.1 a.localhost\n#{FINISH}", %w[a.localhost])
    assert H.block_matches_hostnames?("#{START}\n127.0.0.1 a.localhost b.localhost # c\n#{FINISH}", %w[a.localhost b.localhost])
    assert H.block_matches_hostnames?("", [])
  end

  def test_should_auto_sync_hosts
    assert H.should_auto_sync_hosts?(nil)
    assert H.should_auto_sync_hosts?("1")
    refute H.should_auto_sync_hosts?("0")
    refute H.should_auto_sync_hosts?("false")
  end

  def test_sync_writes_verifies_and_skips_a_matching_block
    assert H.sync_hosts_file(%w[a.localhost b.localhost])
    assert_includes content, "127.0.0.1 a.localhost"
    assert_includes content, "::1\tlocalhost"
    mtime = File.mtime(@file.path)
    sleep 0.01
    assert H.sync_hosts_file(%w[a.localhost b.localhost])
    assert_equal mtime, File.mtime(@file.path)
    assert_equal 1, content.scan(START).size

    assert H.sync_hosts_file(%w[c.localhost])
    refute_includes content, "a.localhost"
    assert_equal %w[c.localhost], H.get_managed_hostnames

    assert H.sync_hosts_file([])
    refute_includes content, START
  end

  def test_clean_removes_only_the_block
    H.sync_hosts_file(%w[a.localhost])
    assert H.clean_hosts_file
    refute_includes content, START
    assert_includes content, "127.0.0.1\tlocalhost"
    assert H.clean_hosts_file
  end

  def test_unreadable_file_reports_failure
    H.hosts_path = File.join(Dir.tmpdir, "missing-hosts-#{Process.pid}")
    refute H.sync_hosts_file(%w[a.localhost])
    refute H.clean_hosts_file
    assert_equal [], H.get_managed_hostnames
  end

  def test_check_host_resolution
    assert H.check_host_resolution("localhost")
  end
end
