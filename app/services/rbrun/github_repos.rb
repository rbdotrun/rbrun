require "faraday"

module Rbrun
  # Lists the repositories the configured github_pat can reach — the workspace directory behind the
  # sidebar repo switcher. The PAT is the source of truth (no local repo registry): an empty query
  # returns the most-recently-updated repos, a query FILTERS those same reachable repos (never global
  # GitHub search — the switcher only offers repos the token can actually act in). All outbound HTTP is
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

    # Search the token's OWN reachable repos (owner + collaborator + org member) — NOT global GitHub. A
    # blank query returns the recent list; otherwise fetch a generous page of the affiliation list and
    # filter by full_name (case-insensitive substring). Scoping to what the PAT can see is the whole
    # point of the switcher; global /search/repositories would surface the entire of GitHub.
    def search(query:, per_page: 30)
      q = query.to_s.strip.downcase
      return list(per_page:) if q.empty?

      list(per_page: 100).select { |r| r.full_name.downcase.include?(q) }.first(per_page)
    end

    # The repo's ACTUAL default branch, straight from the API — the authoritative source when a caller
    # needs to branch off it. Fails loud if the repo can't be read or the API omits it; NEVER guesses a
    # literal like "main" (a repo's default may be master/develop/… — a wrong base breaks provisioning).
    def default_branch(full_name)
      body = get("/repos/#{full_name}")
      body["default_branch"].presence or raise Error, "no default_branch for #{full_name}"
    end

    private

      def to_repo(hash)
        Repo.new(full_name: hash["full_name"], default_branch: hash["default_branch"],
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
