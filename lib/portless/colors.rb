# frozen_string_literal: true

module Portless
  # ANSI colours for CLI output, mirroring portless's colors.ts: only bold,
  # dim, red and yellow emit codes (green/blue/cyan/white are identity).
  # NO_COLOR disables; FORCE_COLOR forces unless "0"/"false"; else TTY decides.
  module Colors
    extend self

    CODES = { bold: [ 1, 22 ], dim: [ 2, 22 ], gray: [ 2, 22 ], red: [ 31, 39 ], yellow: [ 33, 39 ] }.freeze
    IDENTITY = %i[green blue cyan white].freeze
    COLOR_CODES = /\e\[(?:1|2|22|31|33|39)m/

    CODES.each_key do |name|
      define_method(name) { |str, io: $stdout| paint(name, str, io: io) }
    end
    IDENTITY.each { |name| define_method(name) { |str, io: $stdout| str.to_s } } # rubocop:disable Lint/UnusedBlockArgument

    def supports_color?(env, tty)
      return false unless env["NO_COLOR"].to_s.empty?
      return !%w[0 false].include?(env["FORCE_COLOR"]) unless env["FORCE_COLOR"].nil?

      tty
    end

    def paint(name, str, io: $stdout)
      return str.to_s unless enabled?(io)

      open, close = CODES.fetch(name)
      "\e[#{open}m#{str}\e[#{close}m"
    end

    def enabled?(io)
      supports_color?(ENV, io.respond_to?(:tty?) && io.tty?)
    end

    def strip(text) = text.to_s.gsub(COLOR_CODES, "")
  end
end
