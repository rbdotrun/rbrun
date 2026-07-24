# frozen_string_literal: true

module Rbrun
  module Server
    # Adapters DECLARE the config they require; construction validates it in ONE place, so a provider
    # config is either VALID or it RAISES — never "valid-looking". A placeholder that satisfies a check
    # (a fake api key, a guessed model) is the failure mode this exists to prevent: it makes an invalid
    # config pass, and the real failure then surfaces on the first live call, far from the cause.
    #
    # Duplicated per family gem on purpose: a provider gem depends on nothing (invariant #1), so there
    # is no shared base to hang this on.
    module Requires
      def requires(*keys) = @required_keys = keys
      def required_keys = @required_keys ||= []

      def validate_config!(config)
        missing = required_keys.select do |key|
          value = config[key]
          value.nil? || (value.respond_to?(:strip) ? value.strip.empty? : value.to_s.empty?)
        end
        return if missing.empty?

        raise Error, "#{name.split("::").last}: missing required config — #{missing.join(", ")}"
      end
    end
  end
end
