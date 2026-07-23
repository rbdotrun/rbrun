module RbrunFactories
  def rbrun_worktree(tenant: "acme", repo: "acme/webapp", base: "main")
    Rbrun::Worktree.create!(tenant:, repo:, base:)
  end

  def rbrun_session(tenant: "acme", worktree: nil)
    Rbrun::Session.create!(worktree: worktree || rbrun_worktree(tenant:))
  end
end

class ActiveSupport::TestCase
  include RbrunFactories
end
