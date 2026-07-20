require "test_helper"

module Rbrun
  class RepoServiceTest < ActiveSupport::TestCase
    test "requires repo, name, command" do
      rs = Rbrun::RepoService.new(tenant: "rbrun")
      refute rs.valid?
      %i[repo name command].each { |a| assert_includes rs.errors[a], "can't be blank" }
    end

    test "for_repo returns the tenant+repo set in position order" do
      Rbrun::RepoService.create!(tenant: "rbrun", repo: "a/b", name: "web", command: "x", position: 1)
      Rbrun::RepoService.create!(tenant: "rbrun", repo: "a/b", name: "css", command: "y", position: 0)
      Rbrun::RepoService.create!(tenant: "rbrun", repo: "c/d", name: "web", command: "z", position: 0)
      assert_equal %w[css web], Rbrun::RepoService.for_tenant("rbrun").for_repo("a/b").map(&:name)
    end

    test "unique per [tenant, repo, name]" do
      Rbrun::RepoService.create!(tenant: "rbrun", repo: "a/b", name: "web", command: "x")
      assert_raises(ActiveRecord::RecordNotUnique) do
        Rbrun::RepoService.create!(tenant: "rbrun", repo: "a/b", name: "web", command: "y")
      end
    end
  end
end
