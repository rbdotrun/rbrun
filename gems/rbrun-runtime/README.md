# rbrun-runtime

The AI runtime for rbrun: a `claude_sdk` runner that drives a self-contained Claude Agent SDK loop
(`client.ts`) inside a sandbox over an NDJSON stdio bridge, services tools back in Ruby, and streams
normalized events. Depends on `rbrun-sandbox`; the loop runs on `local` and `daytona` unchanged.
