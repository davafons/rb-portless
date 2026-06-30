# frozen_string_literal: true

module Portless
  # ANSI colours for CLI output. A no-op when the target stream isn't a TTY (so
  # piped/redirected output stays clean) or when NO_COLOR is set. Mirrors
  # portless's `colors` helper.
  module Colors
    extend self

    CODES = { bold: 1, dim: 90, gray: 90, red: 31, green: 32, yellow: 33, blue: 34, cyan: 36 }.freeze

    CODES.each_key do |name|
      define_method(name) { |str, io: $stdout| paint(name, str, io: io) }
    end

    def paint(name, str, io: $stdout)
      return str.to_s unless enabled?(io)

      "\e[#{CODES.fetch(name)}m#{str}\e[0m"
    end

    def enabled?(io)
      ENV["NO_COLOR"].to_s.empty? && io.respond_to?(:tty?) && io.tty?
    end
  end
end
