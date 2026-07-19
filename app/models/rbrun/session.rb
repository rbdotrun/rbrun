module Rbrun
  # ONE conversation, under a Worktree (which owns the sandbox + branch). A Session runs turns in the
  # worktree's shared sandbox; its tenant is inherited from the worktree.
  class Session < ApplicationRecord
    include Rbrun::Tenanted

    belongs_to :worktree, class_name: "Rbrun::Worktree"
    before_validation :inherit_tenant, on: :create

    has_many :messages, -> { order(:created_at, :id) },
             class_name: "Rbrun::SessionMessage", dependent: :destroy
    has_many :commits, class_name: "Rbrun::Commit", dependent: :nullify

    belongs_to :workflow, class_name: "Rbrun::Workflow", optional: true
    has_many :workflow_step_completions, class_name: "Rbrun::WorkflowStepCompletion", dependent: :destroy

    enum :status,
         { idle: "idle", working: "working", needs_approval: "needs_approval", done: "done", failed: "failed" },
         default: "idle"

    enum :workflow_status,
         { active: "active", completed: "completed", cancelled: "cancelled" },
         prefix: :workflow_status, validate: { allow_nil: true }

    after_update_commit :broadcast_status, if: :saved_change_to_status?

    # The Worktree's sandbox — one branch checkout shared by all Sessions under it.
    def sandbox = worktree.sandbox

    def display_title = messages.where(role: "user", event_type: "text").order(:id).first&.content.to_s.truncate(80).presence || "New conversation"

    # ── the turn ────────────────────────────────────────────────────────
    def run_turn(content, runtime: nil)
      working!
      before = worktree.head_sha
      turn = Rbrun::AgentTurn.new(session: self, runtime: runtime)
      turn.run(content)
      record_commits!(before)
      turn.gated? ? needs_approval! : done!
      turn
    rescue StandardError => e
      failed!
      messages.create!(role: "assistant", event_type: "error", payload: { "message" => e.message })
      raise
    end

    # Continue after the owner decided a frozen call — the tool already ran; tell the agent. Not a
    # user message (they clicked a button): the decision is logged as an `internal` row.
    def continue_turn!(nudge, runtime: nil)
      working!
      turn = Rbrun::AgentTurn.new(session: self, runtime: runtime)
      turn.continue(nudge)
      turn.gated? ? needs_approval! : done!
      turn
    rescue StandardError => e
      failed!
      raise
    end

    # Resume a failed/retried turn — the SDK session holds the partial state, so it picks up mid-work.
    def resume_turn!(runtime: nil)
      working!
      turn = Rbrun::AgentTurn.new(session: self, runtime: runtime)
      turn.resume
      turn.gated? ? needs_approval! : done!
      turn
    rescue StandardError => e
      failed!
      raise
    end

    # ── the timeline (source of truth for render + live broadcast) ──────
    def open_turn_lead = messages.where(role: "user", event_type: "text").order(:id).last

    # Repaint just the task-progress band (its own target, independent of the composer swap).
    def broadcast_workflow
      ::Turbo::StreamsChannel.broadcast_replace_to("rbrun_session_#{id}",
        target: "workflow_#{id}", partial: "rbrun/sessions/workflow", locals: { session: self })
    end

    def timeline = messages.order(:id).select(&:visible?)

    def turns = timeline.slice_when { |_prev, nxt| nxt.role == "user" }.map { |group| [ group.first, group ] }

    # A single event updates only the SEGMENT it touches — appended (its first appearance) or replaced
    # (a later change) — from the SAME Timeline computation the page-load render uses (live == reload).
    def broadcast_event(message, created:)
      user_message, group = turns.last
      return unless user_message

      timeline = Rbrun::Sessions::Timeline::Component.new(messages: group, working: working?)
      index = timeline.segment_index_for(message)
      return unless index

      if created && timeline.anchor?(message)
        kind, payload = timeline.segment_at(index)
        segment = { kind: kind, payload: payload, results: timeline.results, open: timeline.open_at?(index) }
        ::Turbo::StreamsChannel.broadcast_append_to("rbrun_session_#{id}",
          target: "timeline_#{user_message.id}", partial: "rbrun/sessions/segment", locals: { segment: segment })
      else
        loc = segment_locals_for(message)
        ::Turbo::StreamsChannel.broadcast_replace_to("rbrun_session_#{id}",
          target: loc[:dom_id], partial: "rbrun/sessions/segment", locals: { segment: loc[:segment] })
      end
    end

    # The replace target + locals for one message's segment — same Timeline the render uses, so an
    # in-request render (the approval response) and a live broadcast paint the identical card.
    def segment_locals_for(message)
      user_message, group = turns.last
      return unless user_message

      timeline = Rbrun::Sessions::Timeline::Component.new(messages: group, working: working?)
      index = timeline.segment_index_for(message)
      return unless index

      kind, payload = timeline.segment_at(index)
      { dom_id: timeline.dom_id_at(index),
        segment: { kind: kind, payload: payload, results: timeline.results, open: timeline.open_at?(index) } }
    end

    private

    def inherit_tenant = self.tenant ||= worktree&.tenant

    # Read the commits the agent pushed during the turn (HEAD before → after) and record them.
    # Guarded: a non-git sandbox (unit tests, un-provisioned worktrees) records nothing.
    def record_commits!(before)
      after = worktree.head_sha
      return if after.nil? || after == before

      range = before ? "#{before}..#{after}" : after
      out = worktree.sandbox.exec("cd #{worktree.sandbox.workspace} && git log --format='%H%x09%s' #{range} 2>/dev/null")
      return unless out.success?

      out.stdout.each_line do |line|
        sha, message = line.strip.split("\t", 2)
        next if sha.to_s.empty?

        worktree.commits.find_or_create_by!(sha: sha) { |c| c.session = self; c.message = message }
      end
    end

    # On every working↔done flip: swap the composer (input ⇄ spinner) + the working indicator.
    def broadcast_status
      broadcast_composer
      broadcast_working
    end

    def broadcast_composer
      form = Rbrun::ApplicationController.render(partial: "rbrun/messages/form", locals: { session: self, working: working? })
      ::Turbo::StreamsChannel.broadcast_replace_to("rbrun_session_#{id}", target: "composer",
        html: %(<div id="composer" class="flex-shrink-0 border-t border-slate-200">) +
              %(<div class="mx-auto w-full max-w-3xl p-4">#{form}</div></div>))
    end

    def broadcast_working
      ::Turbo::StreamsChannel.broadcast_replace_to("rbrun_session_#{id}",
        target: "agent_working_#{id}", partial: "rbrun/sessions/working", locals: { session: self })
    end
  end
end
