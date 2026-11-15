# frozen_string_literal: true

module Portless
  # A mistake in how a command was invoked: printed with its hints, exit 2.
  class UsageError < Error
    attr_reader :hints

    def initialize(message, hints = [])
      super(message)
      @hints = hints
    end
  end

  # Strict flag parsing shared by every subcommand. Mirrors portless's
  # args.ts: `--flag value`, `--flag=value`, repeated flags, `--`; unknown
  # flags are rejected with a did-you-mean. Flag kinds: :boolean, :value
  # (non-empty), :text (may be empty).
  module Args
    module_function

    Parsed = Struct.new(:positionals, :seen) do
      def has?(flag) = seen.key?(flag)
      def values(flag) = seen.fetch(flag, [])
      def value(flag) = seen[flag]&.first
    end

    def help_hint(command) = command.empty? ? [] : [ "See: rb-portless #{command} --help" ]

    # => [flag, value, end_index]
    def read_flag_token(command, args, index, spec)
      arg = args[index]
      eq = arg.start_with?("--") ? arg.index("=") : nil
      flag = eq ? arg[0...eq] : arg
      kind = spec[flag]
      known = spec.keys
      hint = help_hint(command)

      unless kind
        suggestion = Commands.closest_match(flag, known)
        raise UsageError.new(
          "Unknown flag \"#{flag}\"#{command.empty? ? '' : " for rb-portless #{command}"}.",
          [ *(suggestion ? [ "Did you mean #{suggestion}?" ] : []),
            known.empty? ? "This command takes no flags." : "Known flags: #{known.join(', ')}",
            *hint ]
        )
      end

      if kind == :boolean
        raise UsageError.new("#{flag} does not take a value.", hint) if eq

        return [ flag, nil, index ]
      end

      value = eq ? arg[(eq + 1)..] : args[index + 1]
      missing = value.nil? || (kind == :value && value.empty?) || (eq.nil? && value.start_with?("-"))
      raise UsageError.new("#{flag} requires a value.", hint) if missing

      [ flag, value, eq ? index : index + 1 ]
    end

    def parse_command_args(command, args, spec, max_positionals = Float::INFINITY)
      seen = {}
      positionals = []
      i = 0
      while i < args.length
        arg = args[i]
        if arg == "--"
          positionals.concat(args[(i + 1)..])
          break
        end
        if !arg.start_with?("-") || arg == "-"
          positionals << arg
          i += 1
          next
        end
        flag, value, last = read_flag_token(command, args, i, spec)
        (seen[flag] ||= []).concat(value.nil? ? [] : [ value ])
        i = last + 1
      end

      if positionals.length > max_positionals
        raise UsageError.new("Unexpected argument \"#{positionals[max_positionals]}\" for rb-portless #{command}.",
                             help_hint(command))
      end
      Parsed.new(positionals, seen)
    end

    # Visit leading flags until `--` or the first positional; returns the rest
    # (the child command) untouched.
    def visit_leading_flags(command, args, spec)
      i = 0
      while i < args.length
        arg = args[i]
        return args[(i + 1)..] if arg == "--"
        return args[i..] if !arg.start_with?("-") || arg == "-"

        flag, value, last = read_flag_token(command, args, i, spec)
        yield flag, value
        i = last + 1
      end
      []
    end
  end
end
