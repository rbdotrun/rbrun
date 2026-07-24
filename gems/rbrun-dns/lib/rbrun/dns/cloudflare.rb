# frozen_string_literal: true

require "json"
require "cgi"
require "faraday"
require "async/http/faraday"

module Rbrun
  module Dns
    # Cloudflare DNS, and nothing else — one zone's records. FARADAY ON ASYNC-HTTP (fork-safe under
    # Falcon), constructed from EXPLICIT credentials, never the environment. Validates its own config and
    # fails fast. Every operation is idempotent by resource identity (name+type), so upsert never
    # duplicates a record. Implements the Rbrun::Dns::Base interface.
    class Cloudflare < Base
      API = "https://api.cloudflare.com/client/v4"

      # `conn:` is an injection seam so tests drive the adapter with Faraday's test adapter (same shape
      # as Rbrun::GithubRepos) — no network, no mocks.
      def initialize(config: {}, conn: nil)
        @token   = config[:api_token]
        @zone_id = config[:zone_id]
        @conn    = conn
        raise Error, "cloudflare dns: api_token missing" if @token.to_s.empty?
        raise Error, "cloudflare dns: zone_id missing"   if @zone_id.to_s.empty?
      end

      # The record with this name (and type, if given), or nil.
      def find(name:, type: nil)
        params = { "name" => name }
        params["type"] = type if type
        record_from(fetch_page("/zones/#{@zone_id}/dns_records", params).first)
      end

      # Every record in the zone, optionally narrowed to a type and/or a host suffix (the suffix filter is
      # applied client-side, so it is adapter-portable). Pages through the whole zone. The Sentinel uses
      # this to see what actually exists at the edge and reconcile it against the DB.
      def list(type: nil, name_suffix: nil)
        params = { "per_page" => 100 }
        params["type"] = type if type
        out = []
        page = 1
        loop do
          params["page"] = page
          result = request(:get, "/zones/#{@zone_id}/dns_records", nil, params)
          batch = Array(result["result"])
          out.concat(batch.map { |raw| record_from(raw) })
          total_pages = result.dig("result_info", "total_pages").to_i
          break if batch.empty? || page >= [ total_pages, 1 ].max

          page += 1
        end
        name_suffix ? out.select { |r| r.name.to_s.end_with?(name_suffix) } : out
      end

      # Create the record if absent, or PATCH it in place if present — so re-running converges and never
      # duplicates. Returns the resulting Record.
      def upsert(name:, type:, content:, proxied: false)
        body = { "type" => type, "name" => name, "content" => content, "proxied" => proxied }
        existing = find(name:, type:)

        raw =
          if existing
            request(:patch, "/zones/#{@zone_id}/dns_records/#{existing.id}", body).fetch("result")
          else
            request(:post, "/zones/#{@zone_id}/dns_records", body).fetch("result")
          end
        record_from(raw)
      end

      # Remove the record (by name+type). True if one was deleted, false if there was nothing to delete.
      def remove(name:, type: nil)
        existing = find(name:, type:)
        return false unless existing

        request(:delete, "/zones/#{@zone_id}/dns_records/#{existing.id}")
        true
      end

      private

        def record_from(raw)
          return nil unless raw

          Record.new(id: raw["id"], name: raw["name"], type: raw["type"],
                     content: raw["content"], proxied: !!raw["proxied"])
        end

        def fetch_page(path, params)
          Array(request(:get, path, nil, params)["result"])
        end

        def request(method, path, body = nil, params = {})
          response = conn.public_send(method, "#{API}#{path}") do |req|
            req.params.update(params) if params.any?
            next if body.nil?

            req.headers["Content-Type"] = "application/json"
            req.body = JSON.generate(body)
          end
          parsed = response.body.is_a?(Hash) ? response.body : (JSON.parse(response.body.to_s) rescue nil)

          # NEVER let "I couldn't read the answer" become "it doesn't exist". Swallowing an unreadable
          # 2xx to {} made find return nil, so upsert took the create branch and POSTed a DUPLICATE
          # record — in the adapter whose docstring promises upsert never duplicates (invariant #11).
          if response.success? && parsed.nil?
            raise Error, "cloudflare dns: unparseable #{response.status} body from #{method.to_s.upcase} #{path}"
          end
          return parsed if response.success? && parsed["success"] != false

          errors = Array((parsed || {})["errors"]).map { |e| e["message"] }.join("; ")
          raise Error, "cloudflare dns: #{method.to_s.upcase} #{path} → #{response.status} #{errors}"
        end

        def conn
          @conn ||= Faraday.new do |f|
            f.response :json, content_type: /\bjson/
            f.headers["Authorization"] = "Bearer #{@token}"
            f.options.open_timeout = 15
            f.options.timeout = 30
            f.adapter :async_http
          end
        end
    end
  end
end
