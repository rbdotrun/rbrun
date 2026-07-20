require "test_helper"

module Rbrun
  class PreviewSentinelJobTest < ActiveJob::TestCase
    # The job is a thin, real delegation to Rbrun::PreviewSentinel — the reconcile logic itself is covered
    # by PreviewSentinelTest at the Rbrun.dns seam. Here we prove the wiring end-to-end with no mocks: with
    # DNS unconfigured (the default test env) the sentinel hits its skip guard, so the job runs the real
    # path and no-ops cleanly — the safety net can never itself blow up a worker.
    test "runs the real sentinel and no-ops safely when the edge is unconfigured" do
      assert_nil Rbrun.config.preview_domain, "guard assumes the test env leaves the edge unconfigured"
      assert_nothing_raised { Rbrun::PreviewSentinelJob.perform_now }
    end

    test "is enqueuable" do
      assert_enqueued_with(job: Rbrun::PreviewSentinelJob) { Rbrun::PreviewSentinelJob.perform_later }
    end
  end
end
