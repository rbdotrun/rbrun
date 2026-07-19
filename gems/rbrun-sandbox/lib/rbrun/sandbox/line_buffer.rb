# frozen_string_literal: true

module Rbrun
  module Sandbox
    # Chunk-to-line normalizer for exec_stream callbacks. Underlying transports deliver bytes in
    # arbitrary chunks; callers want one call per line. Feed raw chunks; the buffer emits complete
    # lines (including the trailing "\n") as they are seen. On stream close call #flush for any
    # trailing partial line.
    class LineBuffer
      def initialize(callback)
        @callback = callback
        @partial  = String.new
      end

      def feed(chunk)
        return if @callback.nil? || chunk.nil? || chunk.empty?

        @partial << chunk
        while (idx = @partial.index("\n"))
          line = @partial.slice!(0..idx) # includes the newline
          @callback.call(line)
        end
      end

      def flush
        return if @callback.nil? || @partial.empty?

        @callback.call(@partial.dup)
        @partial.clear
      end
    end
  end
end
