# rbrun-sandbox

Sandbox backends for rbrun behind one normalized `exec / file / process-session` contract.

```ruby
sandbox = Rbrun::Sandbox.new(provider: :local, config: {}, labels: { session: 1 })
sandbox.exec("echo hi").stdout # => "hi\n"
```

Adapters: `local` (offline host executor), `daytona` (cloud, Faraday + async-http).
Pure Ruby — depends on nothing else in rbrun.
