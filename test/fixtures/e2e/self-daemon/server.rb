# frozen_string_literal: true

# Port of self-daemon/server.mjs: binds $PORT after LISTEN_DELAY_MS.
require "socket"

sleep(Integer(ENV.fetch("LISTEN_DELAY_MS", "0")) / 1000.0)
server = TCPServer.new("127.0.0.1", Integer(ENV.fetch("PORT")))
loop do
  client = server.accept
  client.gets
  nil while (line = client.gets) && line != "\r\n"
  client.write("HTTP/1.1 200 OK\r\nContent-Length: 14\r\nConnection: close\r\n\r\nself-daemon-ok")
  client.close
end
