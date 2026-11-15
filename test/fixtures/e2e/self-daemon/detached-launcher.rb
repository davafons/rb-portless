# frozen_string_literal: true

# Port of detached-launcher.mjs: detaches the server into its own session and
# exits before it binds, like CLIs that double-fork into a daemon.
server = File.join(__dir__, "server.rb")
pid = fork do
  Process.setsid
  exec({ "LISTEN_DELAY_MS" => "500" }, RbConfig.ruby, server, in: File::NULL, out: File::NULL, err: File::NULL)
end
Process.detach(pid)
