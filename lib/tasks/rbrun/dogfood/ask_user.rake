# frozen_string_literal: true

require_relative "support"

# ask_user dogfood — the reference CUSTOM gate. The agent calls the built-in ask_user tool with a
# form_spec; the run PARKS as a pending ask_user gate; the user's picks (recorded as the call's
# tool_result, the ResolvesGate dance) resume the turn, and the agent continues KNOWING the choice.
# Real Claude + Daytona. Creds from .env (ANTHROPIC_OAUTH_TOKEN, DAYTONA_API_KEY).
#
#   bin/rails app:dogfood:ask_user
namespace :dogfood do
  desc "ask_user: the agent asks the user to pick, the run parks, the picks resume the turn"
  task ask_user: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    abort "Missing .env creds." if ENV["ANTHROPIC_OAUTH_TOKEN"].to_s.empty? || ENV["DAYTONA_API_KEY"].to_s.empty?

    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 12 } }
    end
    # ask_user is a built-in, registered + boot-validated in the engine.

    wt = Rbrun::Worktree.create!(tenant: "dogfood", repo: "rbdotrun/dogfood", base: "main")
    session = wt.sessions.create!(tenant: "dogfood")
    begin
      dog.header "the agent asks the user to pick → the run PARKS"
      session.run_turn("Before answering anything else, use the ask_user tool to ask me to choose a color: red or blue. Do NOT guess — ask.")
      session.reload
      frozen = session.messages.approval_pending.last
      dog.ok "the run parked (needs_approval)", session.needs_approval?
      dog.ok "a pending ask_user gate was frozen", frozen&.payload&.dig("name") == "ask_user"
      form = frozen&.payload&.dig("input", "form_spec")
      dog.ok "it carries a form_spec with options", form.is_a?(Hash) && form.to_json.downcase.include?("red")
      dog.info "form_spec", form.to_json.squish[0, 180]

      dog.header "submit VALIDATED picks → recorded as the result, resume with a label recap"
      # The real path (AskUserResponsesController without HTTP): validate the picks against the FROZEN
      # spec (trust boundary), record them, resume with the label-resolved recap.
      spec = Rbrun::AskUserFormSpec.new(form)
      key = spec.keys.first
      value = spec.option_values(key).first                         # a value the agent actually offered
      answers = { key => [ value ] }
      dog.ok "the picks validate against the frozen spec (in-options)", spec.errors(answers).empty?
      dog.ok "an out-of-options value is rejected (the boundary)", spec.errors(key => [ "definitely-not-an-option" ]).any?

      frozen.update!(approval_status: "answered")
      session.messages.create!(role: "tool", event_type: "tool_result", tool_use_id: frozen.tool_use_id,
        content: { "answers" => answers }.to_json,
        payload: { "tool_use_id" => frozen.tool_use_id, "result" => { "answers" => answers }, "is_error" => false })
      session.continue_turn!(spec.recap(answers))
      session.reload

      label = spec.label_for(key, value)
      reply = session.messages.where(event_type: "text", role: "assistant").last&.content.to_s
      dog.ok "the ask_user gate is answered", frozen.reload.approval_answered?
      dog.ok "the turn resumed to done", session.done?
      dog.ok "the agent continued KNOWING the pick (reply reflects the chosen LABEL)",
             reply.downcase.include?(label.to_s.downcase) || reply.downcase.include?(value.to_s.downcase)
      dog.info "pick", "#{key}=#{value} (#{label})"
      dog.info "reply", reply.squish[0, 160]
    ensure
      session.sandbox.destroy!
      wt.destroy!
    end
  end
end
