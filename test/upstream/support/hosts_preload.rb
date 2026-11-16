# frozen_string_literal: true

# Loaded with `ruby -r` into a CLI child by UpstreamCli#run_with_hosts_file_mock
# (upstream's runWithHostsFileMock preload): intercepts /etc/hosts reads and
# writes, sudo, the allowlisted state-file removals and CA update commands, and
# optionally the uid, so nothing touches the real system files or elevates.
require "json"
require "fileutils"
require "open3"

module HostsFileMock
  HOSTS_PATH = "/etc/hosts"
  ORIGINAL_PID = Process.pid
  CAPTURE = { "writes" => [], "sudo" => nil, "sudoCalls" => [] }

  class << self
    attr_accessor :content, :reads
  end
  self.content = ENV["PORTLESS_TEST_HOSTS_CONTENT"] || ""
  self.reads = 0

  FAIL_UNTIL_ELEVATED = ENV["PORTLESS_TEST_FAIL_PRIVILEGED"] == "1"
  FAIL_CA_ONLY = ENV["PORTLESS_TEST_FAIL_CA_ONLY"] == "1"
  STATE_DIRS = begin
    raw = ENV["PORTLESS_INTERNAL_CLEAN_DIRS"]
    if raw && !raw.empty?
      (JSON.parse(raw) rescue []).map { |d| File.expand_path(d.to_s) }
    else
      ENV["PORTLESS_STATE_DIR"] ? [ File.expand_path(ENV["PORTLESS_STATE_DIR"]) ] : []
    end
  end
  MOCK_UID = ENV["PORTLESS_TEST_HOSTS_UID"]&.then { |v| Integer(v) }
  REAL_UID = Process.uid

  module_function

  def elevated? = !ENV["PORTLESS_INTERNAL_CLEAN_STEPS"].to_s.empty?

  def state_path?(file)
    resolved = File.expand_path(file.to_s)
    STATE_DIRS.any? { |d| resolved == d || resolved.start_with?("#{d}/") }
  end

  def deny_removal?(file) = FAIL_UNTIL_ELEVATED && !elevated? && state_path?(file) && File.exist?(file)
  def denied(message) = Errno::EACCES.new(message)

  def remap(stat)
    return stat unless MOCK_UID && stat && stat.uid == REAL_UID

    uid = MOCK_UID
    stat.define_singleton_method(:uid) { uid }
    stat
  end
end

File.singleton_class.prepend(Module.new do
  def read(path, *rest, **kw)
    return super unless path.to_s == HostsFileMock::HOSTS_PATH

    HostsFileMock.reads += 1
    mode = ENV["PORTLESS_TEST_HOSTS_READ_MODE"]
    if mode == "initial-error" || (mode == "verification-error" && HostsFileMock.reads > 1)
      raise HostsFileMock.denied("hosts read failed")
    end
    HostsFileMock.content.dup
  end

  def write(path, data, *rest, **kw)
    return super unless path.to_s == HostsFileMock::HOSTS_PATH

    HostsFileMock::CAPTURE["writes"] << data.to_s
    mode = ENV["PORTLESS_TEST_HOSTS_WRITE_MODE"]
    raise HostsFileMock.denied("hosts write failed") if mode == "error" || (mode == "privileged" && !HostsFileMock.elevated?)

    HostsFileMock.content = data.to_s
    data.to_s.bytesize
  end

  def unlink(*files)
    files.each { |f| raise HostsFileMock.denied("state file removal denied") if HostsFileMock.deny_removal?(f) }
    super
  end

  def delete(*files)
    files.each { |f| raise HostsFileMock.denied("state file removal denied") if HostsFileMock.deny_removal?(f) }
    super
  end

  if HostsFileMock::MOCK_UID
    def lstat(*args) = HostsFileMock.remap(super)
    def stat(*args) = HostsFileMock.remap(super)
  end
end)

FileUtils.singleton_class.prepend(Module.new do
  %i[rm_rf rm_r rm_f rm remove_entry remove_entry_secure].each do |name|
    define_method(name) do |list, *rest, **kw|
      Array(list).each { |f| raise HostsFileMock.denied("state file removal denied") if HostsFileMock.deny_removal?(f) }
      super(list, *rest, **kw)
    end
  end
end)

if HostsFileMock::MOCK_UID
  Process.singleton_class.prepend(Module.new do
    def uid = HostsFileMock::MOCK_UID
  end)
end

Open3.singleton_class.prepend(Module.new do
  def popen3(*cmd, **opts, &block)
    args = cmd.first.is_a?(Hash) ? cmd[1..] : cmd
    if (HostsFileMock::FAIL_UNTIL_ELEVATED || HostsFileMock::FAIL_CA_ONLY) &&
       args.first.to_s.match?(/\Aupdate-ca-(certificates|trust)\z/)
      if !HostsFileMock.elevated? || ENV["PORTLESS_TEST_FAIL_CA_ALWAYS"] == "1"
        raise HostsFileMock.denied("CA update denied")
      end

      return super("true", **opts, &block)
    end
    super
  end
end)

Process.singleton_class.prepend(Module.new do
  def spawn(*args, **opts)
    env = args.first.is_a?(Hash) ? args.shift : nil
    return super(*[ env, *args ].compact, **opts) unless args.first == "sudo"

    sudo_args = args[1..].map(&:to_s)
    call = { "command" => "sudo", "args" => sudo_args }
    HostsFileMock::CAPTURE["sudo"] = call
    HostsFileMock::CAPTURE["sudoCalls"] << call
    return super(*[ env, *sudo_args ].compact, **opts) if ENV["PORTLESS_TEST_SUDO_RUNS"] == "1"

    super("sh", "-c", "exit #{Integer(ENV['PORTLESS_TEST_HOSTS_SUDO_STATUS'] || '1')}", **opts)
  end
end)

at_exit do
  if Process.pid == HostsFileMock::ORIGINAL_PID
    capture = HostsFileMock::CAPTURE.merge("content" => HostsFileMock.content)
    File.open(ENV["PORTLESS_TEST_HOSTS_CAPTURE"], "w") { |f| f.write(JSON.generate(capture)) }
  end
end
