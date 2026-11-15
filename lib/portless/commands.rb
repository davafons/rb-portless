# frozen_string_literal: true

module Portless
  # Reserved subcommand words and "did you mean" matching. Mirrors
  # portless's commands.ts.
  module Commands
    module_function

    COMMAND_NAMES = %w[run get list alias compose proxy service hosts doctor trust clean prune mcp].freeze

    def command_name?(word) = !word.nil? && COMMAND_NAMES.include?(word)

    # --help/-h anywhere after the command word (for commands that don't wrap another).
    def help_flag?(args) = args.drop(1).any? { |a| a == "--help" || a == "-h" }

    # Damerau-Levenshtein (adjacent transposition counts as one edit).
    def edit_distance(a, b)
      d = Array.new(a.length + 1) { |i| Array.new(b.length + 1) { |j| i.zero? ? j : (j.zero? ? i : 0) } }
      (1..a.length).each do |i|
        (1..b.length).each do |j|
          cost = a[i - 1] == b[j - 1] ? 0 : 1
          d[i][j] = [ d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost ].min
          if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]
            d[i][j] = [ d[i][j], d[i - 2][j - 2] + 1 ].min
          end
        end
      end
      d[a.length][b.length]
    end

    # The candidate exactly one edit away, if exactly one is.
    def closest_match(word, candidates)
      matches = candidates.select { |c| edit_distance(word, c) == 1 }
      matches.length == 1 ? matches.first : nil
    end

    def suggest_command(word) = word ? closest_match(word, COMMAND_NAMES) : nil
  end
end
