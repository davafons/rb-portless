# frozen_string_literal: true

# Port of tests/e2e/fixtures/minimal-server/server.js: answers every request
# with "ok:<APP_NAME>" on 127.0.0.1:$PORT.
require "socket"

port = Integer(ENV.fetch("PORT", "3000"))
name = ENV.fetch("APP_NAME", "minimal")
server = TCPServer.new("127.0.0.1", port)
$stdout.sync = true
puts "#{name} listening on http://127.0.0.1:#{port}"

loop do
  client = server.accept
  Thread.new(client) do |conn|
    conn.gets
    nil while (line = conn.gets) && line != "\r\n"
    body = "ok:#{name}"
    conn.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: #{body.bytesize}\r\n" \
               "Connection: close\r\n\r\n#{body}")
  rescue StandardError
    nil
  ensure
    conn.close
  end
end
