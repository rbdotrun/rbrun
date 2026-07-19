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
  end
end
