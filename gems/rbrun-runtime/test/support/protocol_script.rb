# frozen_string_literal: true

# Plays the client side of the NDJSON protocol for the loop test — a REAL detached process.
# Emits session → assistant → tool_request, waits for the tool_response on stdin, then emits result.
require "json"

$stdout.sync = true
puts({ type: "session", session_id: "sess-xyz" }.to_json)
puts({ type: "assistant", text: "working" }.to_json)
puts({ type: "tool_request", id: "t1", name: "add", args: { a: 2, b: 3 } }.to_json)
line = $stdin.gets           # blocks until Ruby answers over the bridge
resp = JSON.parse(line)      # { "type":"tool_response","id":"t1","result":{...},"is_error":false }
puts({ type: "result", session_id: "sess-xyz", subtype: "success", errors: nil,
       stop_reason: "end_turn", structured_output: { "echoed" => resp["result"] } }.to_json)
