# frozen_string_literal: true

require "fileutils"

module Portless
  # /etc/hosts management for resolvers that don't special-case .localhost
  # (Safari, custom TLDs). Chrome/Firefox/Edge auto-resolve *.localhost, so this
  # is a fallback. Entries live in a fenced, idempotent block. Mirrors
  # portless's hosts.ts.
  module Hosts
    module_function

    def file
      Constants::WINDOWS ? File.join(ENV.fetch("SystemRoot", "C:/Windows"), "System32/drivers/etc/hosts") : "/etc/hosts"
    end

    # Replace the managed block with one 127.0.0.1 line per hostname.
    def sync(hostnames)
      block = build_block(hostnames)
      write(strip_block(read) + (block.empty? ? "" : "\n#{block}\n"))
    end

    def clean
      write(strip_block(read))
    end

    def build_block(hostnames)
      return "" if hostnames.empty?
      lines = hostnames.uniq.map { |h| "127.0.0.1\t#{h}" }
      [ Constants::HOSTS_BEGIN, *lines, Constants::HOSTS_END ].join("\n")
    end

    def strip_block(text)
      text.gsub(/\n*#{Regexp.escape(Constants::HOSTS_BEGIN)}.*?#{Regexp.escape(Constants::HOSTS_END)}\n*/m, "\n")
    end

    def read
      File.exist?(file) ? File.read(file) : ""
    end

    def write(content)
      File.write(file, content.gsub(/\n{3,}/, "\n\n"))
    rescue Errno::EACCES
      raise Error, "writing #{file} needs root — re-run via sudo (rb-portless hosts sync)"
    end
  end
end
