# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# Shared helpers for the config/auto/workspace/turbo mirrors.
module UpstreamConfigSupport
  module_function

  def create_tmp_dir(prefix) = Dir.mktmpdir(prefix)

  def cleanup_dir(dir) = FileUtils.rm_rf(dir)

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def write_json(path, value) = write(path, JSON.generate(value))
end
