#!/bin/sh
# Port of self-daemon/launcher.sh: starts the server in the background and
# exits before it is listening, like CLIs that self-daemonize.
"${RUBY:-ruby}" "$(dirname "$0")/server.rb" > /dev/null 2>&1 &
exit 0
