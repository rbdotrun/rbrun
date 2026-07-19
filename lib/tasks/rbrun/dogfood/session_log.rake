# frozen_string_literal: true

require_relative "support"

# Phase 4 dogfood — the persistence + config spine, for real (real DB, real config). Creates a
# Session as a tenant, appends event-log rows exactly as the turn loop will (Phase 5), and proves
# they persist, scope by tenant, thread to their turn, and that the config-aware constructors resolve.
# Needs :environment (the DB + config).
#
#   bin/rails app:dogfood:session_log

namespace :dogfood do
  desc "Phase 4: a Session persists an event log, scopes by tenant, and resolves its sandbox/runtime"
  task session_log: :environment do
    dog = Rbrun::Dogfood

    session = Rbrun::Session.create!(tenant: "dogfood")
    lead = session.messages.create!(role: "user", event_type: "text", content: "build me a report")
    session.messages.create!(role: "assistant", event_type: "session", payload: { "session_id" => "sess-abc" })
    session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "t1",
                             user_message: lead, payload: { "name" => "add", "input" => { "a" => 2, "b" => 3 } })
    session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "t2",
                             approval_status: "pending", user_message: lead, payload: { "name" => "deploy" })
    session.update!(sdk_session_id: "sess-abc", status: "needs_approval")

    dog.header "persistence"
    dog.ok "session persisted with 4 event rows", session.messages.count == 4
    dog.ok "sdk_session_id stored", session.reload.sdk_session_id == "sess-abc"
    dog.ok "status is needs_approval", session.needs_approval?

    dog.header "tenancy"
    other = Rbrun::Session.create!(tenant: "someone-else")
    dog.ok "for_tenant('dogfood') finds our session", Rbrun::Session.for_tenant("dogfood").include?(session)
    dog.ok "for_tenant('dogfood') excludes the other tenant", !Rbrun::Session.for_tenant("dogfood").include?(other)

    dog.header "event log shape"
    dog.ok "one frozen (gated) tool_use row", session.messages.gated.count == 1
    dog.ok "agent rows thread to the user lead", session.messages.where(user_message_id: lead.id).count == 2

    dog.header "config-aware constructors"
    box = session.sandbox
    dog.ok "session.sandbox resolved from config (:local)", box.is_a?(Rbrun::Sandbox::Local)
    dog.ok "Rbrun.runtime resolves claude_sdk", Rbrun.runtime(sandbox: box).is_a?(Rbrun::Runtime::ClaudeSdk)

    box.destroy!
    session.destroy!
    other.destroy!
    dog.info "cleanup", "sessions destroyed"
  end
end
