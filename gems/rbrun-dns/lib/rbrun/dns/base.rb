# frozen_string_literal: true

module Rbrun
  module Dns
    # The interface every DNS adapter MUST implement — the contract the engine and the Sentinel rely on,
    # independent of which provider is configured. Adapters inherit from Base and override each method; a
    # provider that forgets one fails loudly with NotImplementedError instead of a confusing NoMethodError.
    # Pure documentation + enforcement: no behaviour, no state, no dependencies.
    #
    # Records are keyed by resource identity (name, plus type where given). Every mutating method MUST be
    # idempotent — upsert never duplicates, remove is a no-op when absent — so callers can re-run freely
    # (invariant #11). Methods return Rbrun::Dns::Record (or nil / a boolean, as documented).
    class Base
      # The record matching this name (and type, if given), or nil.
      # @return [Record, nil]
      def find(name:, type: nil)
        raise NotImplementedError, "#{self.class}#find"
      end

      # Every record in the zone, optionally narrowed to a type and/or a host suffix (the suffix filter is
      # applied client-side, so it stays adapter-portable). The Sentinel uses this to see what exists at the
      # edge and reconcile it against the DB.
      # @return [Array<Record>]
      def list(type: nil, name_suffix: nil)
        raise NotImplementedError, "#{self.class}#list"
      end

      # Create the record if absent, or update it in place if present — so re-running converges and never
      # duplicates.
      # @return [Record]
      def upsert(name:, type:, content:, proxied: false)
        raise NotImplementedError, "#{self.class}#upsert"
      end

      # Remove the record (by name, plus type where given). True if one was deleted, false if there was
      # nothing to delete.
      # @return [Boolean]
      def remove(name:, type: nil)
        raise NotImplementedError, "#{self.class}#remove"
      end
    end
  end
end
