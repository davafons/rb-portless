# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/core"

# Mirror of packages/portless/src/hosts.test.ts
#
# Upstream mocks fs.readFileSync/writeFileSync. Here the hosts path points at
# a temp file (never /etc/hosts) and File.read/File.write are stubbed for that
# path only, with the same once/default/throw controls as vi.mocked.
module HostsMirror
  H = Portless::Hosts

  # vi.mocked(fn) stand-in: queued one-shot behaviours, then a default.
  class FsMock
    attr_reader :calls

    def initialize
      @once = []
      @default = nil
      @calls = []
    end

    def mock_return_value(value) = tap { @default = ->(*) { value } }
    def mock_return_value_once(value) = tap { @once << ->(*) { value } }
    def mock_implementation(impl) = tap { @default = impl }
    def mock_implementation_once(impl) = tap { @once << impl }

    def call(*args)
      @calls << args
      impl = @once.shift || @default
      impl&.call(*args)
    end
  end

  def self.included(base)
    base.class_eval do
      before do
        @hosts_dir = Dir.mktmpdir("portless-hosts-test-")
        H.hosts_path = File.join(@hosts_dir, "hosts")
        @read_file_sync = FsMock.new
        @write_file_sync = FsMock.new
      end

      after do
        H.hosts_path = nil
        FileUtils.rm_rf(@hosts_dir)
      end
    end
  end

  attr_reader :read_file_sync, :write_file_sync

  # Run the block with File.read/File.write on the hosts path routed to the mocks.
  def with_fs_mocks(&block)
    real_read = File.method(:read)
    real_write = File.method(:write)
    hosts = H.hosts_path
    read = ->(path, *rest, **kw) { path == hosts ? @read_file_sync.call(path) : real_read.call(path, *rest, **kw) }
    write = lambda do |path, data, *rest, **kw|
      path == hosts ? @write_file_sync.call(path, data) : real_write.call(path, data, *rest, **kw)
    end
    File.stub(:read, read) { File.stub(:write, write, &block) }
  end

  def extract_managed_block(content) = H.extract_managed_block(content)
  def remove_block(content) = H.remove_block(content)
  def build_block(hostnames) = H.build_block(hostnames)
  def should_auto_sync_hosts(value) = H.should_auto_sync_hosts?(value)
  def check_host_resolution(hostname) = H.check_host_resolution(hostname)
  def block_matches_hostnames(content, hostnames) = H.block_matches_hostnames?(content, hostnames)
  def sync_hosts_file(hostnames) = with_fs_mocks { H.sync_hosts_file(hostnames) }
  def clean_hosts_file = with_fs_mocks { H.clean_hosts_file }
  def get_managed_hostnames = with_fs_mocks { H.get_managed_hostnames }
end

# ---------------------------------------------------------------------------
# extractManagedBlock
# ---------------------------------------------------------------------------

describe "extractManagedBlock" do
  include HostsMirror

  it "returns empty array when no markers exist" do
    content = "127.0.0.1 localhost\n::1 localhost\n"
    assert_equal [], extract_managed_block(content)
  end

  it "returns empty array when only start marker exists" do
    content = "# rb-portless-start\n127.0.0.1 myapp.localhost\n"
    assert_equal [], extract_managed_block(content)
  end

  it "returns empty array when only end marker exists" do
    content = "127.0.0.1 myapp.localhost\n# rb-portless-end\n"
    assert_equal [], extract_managed_block(content)
  end

  it "returns empty array when end marker comes before start marker" do
    content = "# rb-portless-end\n127.0.0.1 myapp.localhost\n# rb-portless-start\n"
    assert_equal [], extract_managed_block(content)
  end

  it "extracts lines between markers" do
    content = [
      "127.0.0.1 localhost",
      "# rb-portless-start",
      "127.0.0.1 myapp.localhost",
      "127.0.0.1 api.localhost",
      "# rb-portless-end",
      ""
    ].join("\n")
    assert_equal [ "127.0.0.1 myapp.localhost", "127.0.0.1 api.localhost" ], extract_managed_block(content)
  end

  it "trims whitespace from extracted lines" do
    content = "# rb-portless-start\n  127.0.0.1 myapp.localhost  \n# rb-portless-end\n"
    assert_equal [ "127.0.0.1 myapp.localhost" ], extract_managed_block(content)
  end

  it "filters out empty lines" do
    content = "# rb-portless-start\n\n127.0.0.1 myapp.localhost\n\n# rb-portless-end\n"
    assert_equal [ "127.0.0.1 myapp.localhost" ], extract_managed_block(content)
  end

  it "returns empty array when block is empty" do
    content = "# rb-portless-start\n# rb-portless-end\n"
    assert_equal [], extract_managed_block(content)
  end
end

# ---------------------------------------------------------------------------
# removeBlock
# ---------------------------------------------------------------------------

describe "removeBlock" do
  include HostsMirror

  it "returns content unchanged when no markers exist" do
    content = "127.0.0.1 localhost\n"
    assert_equal "127.0.0.1 localhost\n", remove_block(content)
  end

  it "removes the managed block and normalizes newlines" do
    content = [
      "127.0.0.1 localhost",
      "",
      "# rb-portless-start",
      "127.0.0.1 myapp.localhost",
      "# rb-portless-end",
      ""
    ].join("\n")
    result = remove_block(content)
    refute_includes result, "rb-portless-start"
    refute_includes result, "myapp.localhost"
    assert_includes result, "127.0.0.1 localhost"
    assert_equal true, result.end_with?("\n")
  end

  it "does not leave more than 2 consecutive newlines" do
    content =
      "127.0.0.1 localhost\n\n\n# rb-portless-start\n127.0.0.1 x.localhost\n# rb-portless-end\n\n\nother\n"
    result = remove_block(content)
    refute_match(/\n{3,}/, result)
  end

  it "preserves content before and after the block" do
    content = "before\n# rb-portless-start\nentry\n# rb-portless-end\nafter\n"
    result = remove_block(content)
    assert_includes result, "before"
    assert_includes result, "after"
  end
end

# ---------------------------------------------------------------------------
# buildBlock
# ---------------------------------------------------------------------------

describe "buildBlock" do
  include HostsMirror

  it "returns empty string for empty hostnames array" do
    assert_equal "", build_block([])
  end

  it "builds a single-entry block with markers" do
    result = build_block([ "myapp.localhost" ])
    assert_equal "# rb-portless-start\n127.0.0.1 myapp.localhost\n# rb-portless-end", result
  end

  it "builds a multi-entry block" do
    result = build_block([ "myapp.localhost", "api.localhost" ])
    lines = result.split("\n")
    assert_equal "# rb-portless-start", lines[0]
    assert_equal "127.0.0.1 myapp.localhost", lines[1]
    assert_equal "127.0.0.1 api.localhost", lines[2]
    assert_equal "# rb-portless-end", lines[3]
  end

  it "produces a block that extractManagedBlock can parse" do
    hostnames = [ "a.localhost", "b.localhost" ]
    block = build_block(hostnames)
    extracted = extract_managed_block(block)
    assert_equal [ "127.0.0.1 a.localhost", "127.0.0.1 b.localhost" ], extracted
  end
end

# ---------------------------------------------------------------------------
# shouldAutoSyncHosts
# ---------------------------------------------------------------------------

describe "shouldAutoSyncHosts" do
  include HostsMirror

  it "returns true when unset" do
    assert_equal true, should_auto_sync_hosts(nil)
  end

  it "returns false for 0 and false" do
    assert_equal false, should_auto_sync_hosts("0")
    assert_equal false, should_auto_sync_hosts("false")
  end

  it "returns true for 1 and true" do
    assert_equal true, should_auto_sync_hosts("1")
    assert_equal true, should_auto_sync_hosts("true")
  end

  it "returns true for other non-empty values" do
    assert_equal true, should_auto_sync_hosts("yes")
    assert_equal true, should_auto_sync_hosts("")
  end
end

# ---------------------------------------------------------------------------
# checkHostResolution
# ---------------------------------------------------------------------------

describe "checkHostResolution" do
  include HostsMirror

  it "accepts localhost through either loopback family" do
    assert_equal true, check_host_resolution("localhost")
  end

  it "accepts IPv4 loopback" do
    assert_equal true, check_host_resolution("127.0.0.1")
  end

  it "accepts IPv6 loopback" do
    assert_equal true, check_host_resolution("::1")
  end

  it "rejects non-loopback IPv4" do
    assert_equal false, check_host_resolution("198.51.100.7")
  end

  it "rejects non-loopback IPv6" do
    assert_equal false, check_host_resolution("2001:db8::1")
  end

  it "returns false for a nonexistent domain" do
    assert_equal false, check_host_resolution("this-should-never-exist.invalid")
  end
end

# syncHostsFile verifies that the readable managed block exactly matches the
# requested hostnames. This pure predicate pins that exact verification without
# depending on the hosts path, which is a module constant.
describe "blockMatchesHostnames" do
  include HostsMirror

  def block = "# rb-portless-start\n127.0.0.1 a.localhost\n127.0.0.1 b.localhost\n# rb-portless-end"

  it "is true only when the block is exactly the wanted set" do
    assert_equal true, block_matches_hostnames(block, [ "a.localhost", "b.localhost" ])
    assert_equal true, block_matches_hostnames("127.0.0.1 localhost\n#{block}\n", [ "b.localhost", "a.localhost" ])
  end

  it "is false when a hostname is missing" do
    assert_equal false, block_matches_hostnames(block, [ "a.localhost", "c.localhost" ])
    assert_equal false, block_matches_hostnames("127.0.0.1 localhost\n", [ "a.localhost" ])
  end

  # The defect a subset test cannot see. A removed route leaves its hostname in
  # the block; if that still counts as correct, the sync skips its write and the
  # stale entry resolves forever.
  it "is false when the block carries a hostname that is no longer wanted" do
    assert_equal false, block_matches_hostnames(block, [ "a.localhost" ])
  end

  it "is false when an extra hostname shares a wanted line" do
    aliases = "# rb-portless-start\n127.0.0.1 a.localhost stale.localhost\n# rb-portless-end"
    assert_equal false, block_matches_hostnames(aliases, [ "a.localhost" ])
  end

  it "ignores inline comments after all hostname aliases" do
    commented = "# rb-portless-start\n127.0.0.1 a.localhost # managed\n# rb-portless-end"
    assert_equal true, block_matches_hostnames(commented, [ "a.localhost" ])
  end

  # A line only helps if it points at loopback.
  it "is false when a wanted hostname maps to another address" do
    wrong = "# rb-portless-start\n10.0.0.1 a.localhost\n# rb-portless-end"
    assert_equal false, block_matches_hostnames(wrong, [ "a.localhost" ])
  end

  it "is false on a duplicate entry, which is not what a sync would write" do
    dupe = "# rb-portless-start\n127.0.0.1 a.localhost\n127.0.0.1 a.localhost\n# rb-portless-end"
    assert_equal false, block_matches_hostnames(dupe, [ "a.localhost" ])
  end

  it "ignores entries outside the managed block" do
    assert_equal false, block_matches_hostnames("127.0.0.1 a.localhost\n", [ "a.localhost" ])
  end

  it "treats no hostnames as satisfied only when no block remains" do
    assert_equal true, block_matches_hostnames("127.0.0.1 localhost\n", [])
    assert_equal false, block_matches_hostnames(block, [])
  end
end

# ---------------------------------------------------------------------------
# Hosts file mutation safety
# ---------------------------------------------------------------------------

describe "hosts file mutation safety" do
  include HostsMirror

  def system_and_custom_entries = "127.0.0.1 localhost\n192.0.2.10 custom.test\n"

  def stale_block
    "127.0.0.1 localhost\n\n# rb-portless-start\n127.0.0.1 stale.test\n# rb-portless-end\n\n192.0.2.10 custom.test\n"
  end

  def throw_read_error = ->(*) { raise Errno::EACCES }

  def use_in_memory_hosts(initial)
    hosts = initial
    read_file_sync.mock_implementation(->(*) { hosts })
    write_file_sync.mock_implementation(->(_, data) { hosts = data.to_s })
    -> { hosts }
  end

  it "does not write when the initial read fails before a populated sync" do
    read_file_sync.mock_implementation_once(throw_read_error).mock_return_value(system_and_custom_entries)

    assert_equal false, sync_hosts_file([ "app.test" ])
    assert_equal 1, read_file_sync.calls.size
    assert_empty write_file_sync.calls
  end

  it "does not write when the initial read fails before an empty sync" do
    read_file_sync.mock_implementation_once(throw_read_error).mock_return_value(stale_block)

    assert_equal false, sync_hosts_file([])
    assert_equal 1, read_file_sync.calls.size
    assert_empty write_file_sync.calls
  end

  it "does not write when the initial read fails before cleanup" do
    read_file_sync.mock_implementation_once(throw_read_error).mock_return_value(stale_block)

    assert_equal false, clean_hosts_file
    assert_equal 1, read_file_sync.calls.size
    assert_empty write_file_sync.calls
  end

  it "returns false when verification cannot read a %s sync" do
    [ [ "populated", [ "app.test" ] ], [ "empty", [] ] ].each do |_description, hostnames|
      @read_file_sync = HostsMirror::FsMock.new
      @write_file_sync = HostsMirror::FsMock.new
      read_file_sync.mock_return_value_once(stale_block).mock_implementation_once(throw_read_error)

      assert_equal false, sync_hosts_file(hostnames)
      assert_equal 1, write_file_sync.calls.size
    end
  end

  it "returns false when the hosts write fails" do
    read_file_sync.mock_return_value(system_and_custom_entries)
    write_file_sync.mock_implementation(->(*) { raise Errno::EACCES })

    assert_equal false, sync_hosts_file([ "app.test" ])
    assert_equal 1, read_file_sync.calls.size
    assert_equal 1, write_file_sync.calls.size
  end

  it "returns false when a successful write does not produce the requested block" do
    read_file_sync.mock_return_value_once(system_and_custom_entries).mock_return_value_once(system_and_custom_entries)

    assert_equal false, sync_hosts_file([ "app.test" ])
    assert_equal 1, write_file_sync.calls.size
  end

  it "treats a readable empty file as an already synchronized empty set" do
    read_file_sync.mock_return_value("")

    assert_equal true, sync_hosts_file([])
    assert_empty write_file_sync.calls
  end

  it "does not rewrite an exact matching block" do
    read_file_sync.mock_return_value("# rb-portless-start\n127.0.0.1 app.test\n# rb-portless-end\n")

    assert_equal true, sync_hosts_file([ "app.test" ])
    assert_empty write_file_sync.calls
  end

  it "removes stale entries while preserving entries before and after the block" do
    hosts = use_in_memory_hosts(stale_block)

    assert_equal true, sync_hosts_file([])
    assert_equal 1, write_file_sync.calls.size
    assert_includes hosts.call, "127.0.0.1 localhost"
    assert_includes hosts.call, "192.0.2.10 custom.test"
    refute_includes hosts.call, "rb-portless-start"
    refute_includes hosts.call, "stale.test"
  end

  it "writes and verifies a replacement block without changing unrelated entries" do
    hosts = use_in_memory_hosts(stale_block)

    assert_equal true, sync_hosts_file([ "app.test" ])
    assert_includes hosts.call, "127.0.0.1 localhost"
    assert_includes hosts.call, "192.0.2.10 custom.test"
    assert_includes hosts.call, "127.0.0.1 app.test"
    refute_includes hosts.call, "stale.test"
  end

  it "keeps getManagedHostnames best-effort on read failure" do
    read_file_sync.mock_implementation(throw_read_error)

    assert_equal [], get_managed_hostnames
  end
end
