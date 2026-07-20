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
    # duplicates a record.
    class Cloudflare
      API = "https://api.cloudflare.com/client/v4"

      def initialize(config: {})
        @token   = config[:api_token]
        @zone_id = config[:zone_id]
        raise Error, "cloudflare dns: api_token missing" if @token.to_s.empty?
        raise Error, "cloudflare dns: zone_id missing"   if @zone_id.to_s.empty?
      end

      # The record with this name (and type, if given), or nil.
      def find(name:, type: nil)
        params = { "name" => name }
        params["type"] = type if type
        record_from(list("/zones/#{@zone_id}/dns_records", params).first)
      end

      # Create the record if absent, or PATCH it in place if present — so re-running converges and never
      # duplicates. Returns the resulting Record.
      def upsert(name:, type:, content:, proxied: false)
        body = { "type" => type, "name" => name, "content" => content, "proxied" => proxied }
        existing = find(name: name, type: type)

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
        existing = find(name: name, type: type)
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

      def list(path, params)
        Array(request(:get, path, nil, params)["result"])
      end

      def request(method, path, body = nil, params = {})
        response = conn.public_send(method, "#{API}#{path}") do |req|
          req.params.update(params) if params.any?
          next if body.nil?

          req.headers["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end
        parsed = response.body.is_a?(Hash) ? response.body : (JSON.parse(response.body.to_s) rescue {})
        return parsed if response.success? && parsed["success"] != false

        errors = Array(parsed["errors"]).map { |e| e["message"] }.join("; ")
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
