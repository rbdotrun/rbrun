# frozen_string_literal: true

# Shared helpers for rbrun dogfood scenarios. These are REAL runs, not tests: run a task and read
# the compact ✓/✗ output, then analyze. One scenario per .rake file in this directory.
module Rbrun
  module Dogfood
    module_function

    def ok(label, cond)
      puts "#{cond ? "✓" : "✗"} #{label}"
      cond
    end

    def info(key, val)
      puts "  #{key}: #{val}"
    end

    def header(text)
      puts "\n── #{text} #{"─" * [ 0, 50 - text.length ].max}"
    end

    # Load repo-root .env into ENV (only keys not already set). Dogfood creds live in .env — a secret
    # store, not a scenario variable. No dotenv gem; a five-line parser is enough.
    def load_env!(path = File.expand_path("../../../../.env", __dir__))
      return unless File.exist?(path)

      File.foreach(path) do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        key, _, value = line.partition("=")
        key = key.strip
        ENV[key] ||= value.strip.gsub(/\A["']|["']\z/, "")
      end
    end
  end
end
