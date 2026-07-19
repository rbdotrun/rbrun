module Rbrun
  module Mcp
    # Spec[] → the `mcp.json` the SDK reads: { "mcpServers" => { name => stdio|http entry } }. Pure;
    # secrets from the Spec's env/headers land in the output (they're written into the sandbox per
    # turn and deleted in `ensure`, never persisted).
    module Materializer
      module_function

      def call(specs)
        { "mcpServers" => specs.to_h { |spec| [ spec.name.to_s, entry(spec) ] } }
      end

      def entry(spec)
        case spec.transport.to_sym
        when :stdio
          { "command" => spec.command, "args" => Array(spec.args), "env" => stringify(spec.env) }
        when :http
          { "type" => "http", "url" => spec.url, "headers" => stringify(spec.headers) }
        else
          raise ArgumentError, "unknown mcp transport: #{spec.transport.inspect}"
        end
      end

      def stringify(hash)
        (hash || {}).to_h { |k, v| [ k.to_s, v.to_s ] }
      end
    end
  end
end
