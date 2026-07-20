# rbrun-dns

DNS providers for rbrun behind one contract, so a host can put its own domain on previews. Pure Ruby,
depends on nothing else in rbrun. Faraday on async-http (fork-safe under Falcon).

```ruby
dns = Rbrun::Dns.new(provider: :cloudflare, config: { api_token:, zone_id: })

dns.upsert(name: "*.rb.run", type: "CNAME", content: "tunnel-id.cfargotunnel.com", proxied: true)
dns.find(name: "*.rb.run", type: "CNAME") # => Rbrun::Dns::Record | nil
dns.remove(name: "*.rb.run", type: "CNAME")
```

Adapters are resolved by constant lookup (`:cloudflare → Cloudflare`) — no registry. Each validates its
own credentials and fails fast. `route53` slots in with no caller change.
