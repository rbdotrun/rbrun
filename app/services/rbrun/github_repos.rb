require "faraday"

module Rbrun
  # Lists the repositories the configured github_pat can reach — the workspace directory behind the
  # sidebar repo switcher. The PAT is the source of truth (no local repo registry): an empty query
  # returns the most-recently-updated repos, a query hits GitHub's search API. All outbound HTTP is
  # Faraday on the async-http adapter (fork-safe under Falcon; invariant #5). The connection is
  # injectable (conn:) so tests drive it with Faraday's test adapter — no network, no mocks.
  class GithubRepos
    API = "https://api.github.com".freeze

    Repo = Data.define(:full_name, :default_branch, :private)

    def initialize(pat:, conn: nil)
      @pat = pat.to_s
      raise ArgumentError, "GithubRepos needs a github_pat (set c.github_pat)" if @pat.empty?

      @conn = conn
    end

    # The token's own repos, most-recently-updated first.
    def list(per_page: 30)
      body = get("/user/repos", sort: "updated", affiliation: "owner,collaborator,organization_member",
                                per_page:)
      Array(body).map { |r| to_repo(r) }
    end

    # A blank query lists; otherwise GitHub search across everything the token sees.
    def search(query:, per_page: 30)
      q = query.to_s.strip
      return list(per_page:) if q.empty?

      body = get("/search/repositories", q:, per_page:)
      Array(body && body["items"]).map { |r| to_repo(r) }
    end

    private

    def to_repo(hash)
      Repo.new(full_name: hash["full_name"], default_branch: hash["default_branch"] || "main",
               private: hash["private"] || false)
    end

    def get(path, **params)
      resp = conn.get(path, params)
      raise Error, "GET #{path} → #{resp.status}: #{resp.body.to_s[0, 200]}" unless resp.success?

      resp.body
    end

    def conn
      @conn ||= begin
        require "async/http/faraday"
        Faraday.new(url: API) do |f|
          f.response :json, content_type: /\bjson/
          f.headers["Authorization"] = "Bearer #{@pat}"
          f.headers["Accept"] = "application/vnd.github+json"
          f.options.open_timeout = 15
          f.adapter :async_http
        end
      end
    end

    class Error < StandardError; end
  end
end
