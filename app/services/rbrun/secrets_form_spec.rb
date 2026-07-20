module Rbrun
  # A read model over the frozen request_secrets declaration (string-keyed) — ONE place answers "which
  # keys / labels / required", so the card, the validator, and the resume nudge never disagree. Mirrors
  # AskUserFormSpec, with the HARD difference that it NEVER handles or echoes a value: `stored_recap`
  # lists only the KEY NAMES that were set.
  class SecretsFormSpec
    def initialize(spec) = @spec = spec || {}

    def secrets = Array(@spec["secrets"])
    def keys    = secrets.map { |s| s["key"].to_s }

    def entry(key)     = secrets.find { |s| s["key"].to_s == key.to_s }
    def label_for(key) = entry(key)&.dig("label").to_s.presence || key
    def hint_for(key)  = entry(key)&.dig("hint").to_s.presence
    def required?(key) = !!entry(key)&.dig("required")

    # The trust boundary: every required key present, and no unknown fields. (Values themselves are
    # opaque — any non-blank string is acceptable.)
    def errors(submitted)
      submitted ||= {}
      msgs = []
      keys.each { |k| msgs << "#{label_for(k)} is required" if required?(k) && submitted[k].to_s.strip.empty? }
      unknown = submitted.keys.map(&:to_s) - keys
      msgs << "unknown fields: #{unknown.join(', ')}" if unknown.any?
      msgs
    end

    # The resume nudge — KEY NAMES ONLY. The agent learns WHICH secrets are set, never a value.
    def stored_recap(stored_keys)
      list = Array(stored_keys).join(", ")
      "Stored #{list}. The secrets are set in the services' environment — continue. You never see the values."
    end
  end
end
