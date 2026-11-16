# frozen_string_literal: true

require "fileutils"
require "json"
require "socket"
require "tmpdir"

# Helpers for the cli-utils.test.ts mirror.
module CliUtilsSupport
  # Set ENV keys for the block (nil deletes), restoring the previous values.
  def with_env(vars)
    saved = vars.keys.to_h { |k| [ k, ENV.fetch(k, nil) ] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # A minimal HTTP server on `host`: answers every request with `headers`
  # and `body` (upstream: http.createServer). Returns [server, port].
  def start_http_server(host = "127.0.0.1", headers: {}, body: "ok")
    server = TCPServer.new(host, 0)
    Thread.new do
      loop do
        client = server.accept
        Thread.new(client) do |c|
          while (line = c.gets) && line != "\r\n"; end
          extra = headers.map { |k, v| "#{k}: #{v}\r\n" }.join
          c.write("HTTP/1.1 200 OK\r\n#{extra}Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        rescue IOError, SystemCallError
          nil
        ensure
          c.close
        end
      end
    rescue IOError, SystemCallError
      nil
    end
    [ server, server.addr[1] ]
  end

  # Write package.json into `dir` (upstream writeScripts / writePackage).
  def write_package(dir, scripts, name: "test-app", package_manager: nil)
    pkg = { name: name }
    pkg[:packageManager] = package_manager if package_manager
    pkg[:scripts] = scripts
    File.write(File.join(dir, "package.json"), JSON.generate(pkg))
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue StandardError
    false
  end

  def monotonic_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)

  def inject_framework_flags(args, port) = Portless::Frameworks.inject_framework_flags(args, port)

  def inject_package_script_framework_flags(args, port, dir)
    Portless::Frameworks.inject_package_script_framework_flags(args, port, dir)
  end

  def resolve_framework_basename(args, dir) = Portless::Frameworks.resolve_framework_basename(args, dir)
end
