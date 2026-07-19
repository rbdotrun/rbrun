# Phase 8 — Engine UI (conversation) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The working conversation UI — mandatory auth, the live broadcast/timeline engine, the ViewComponents (on Phase 7 primitives), controllers/jobs/routes, the 3 Stimulus controllers, a Worktree commit pane — so a logged-in user posts a message, watches the turn stream, approves a gated call, and sees the branch's commits.

**Architecture:** Auth is mandatory (no `c.user` and no host `current_user` override ⇒ raise at boot; every controller requires a session). The turn runs in a job; the model broadcasts over `Turbo::StreamsChannel` — a `Session#broadcast_event` re-uses the `Timeline` segment computation to **append a new segment or replace one in place** (live == reload); `broadcast_status` swaps the composer + working indicator. The `Timeline`/`Segment` components render prose / internal / a tools accordion (with the approval footer on a `pending` gate). The conversation aggregate is `Session`, the sandbox surface is a `Worktree`, and completed work surfaces as a commit pane.

**Tech Stack:** turbo-rails 8, stimulus 3, ActionCable (async adapter for test/dev), ViewComponent (Phase 7 DSL), Tailwind v4 + bun, `redcarpet` (markdown), `lucide-rails`, Minitest.

## Global Constraints

- **Auth is mandatory.** Boot raises (`Rbrun::ConfigError`) unless auth is configured (≥1 `c.user`, or a host `current_user` resolver). Every engine controller `require_authentication`; `current_tenant = current_user.tenant`.
- **The turn runs in a JOB, never inline in a request** (a 30–60s turn dies with the HTTP request). Approvals + resumes enqueue jobs.
- **Append-only log:** `run_turn`/`continue_turn!`/`resume_turn!` rescue `Exception` (for `Async::Cancel`) → `failed!`, never rolling back ingested rows.
- **Live == reload:** broadcasts render segments from the *same* `Timeline` computation the page-load render uses (`broadcast_event` / `segment_locals_for`). Tokens are coalesced server-side — never per-token broadcast.
- **Naming:** `rbrun_session_<id>` stream; `Rbrun::Conversation::*::Component`; a Worktree commit pane is the completed-work region.
- **Dogfood:** `lib/tasks/rbrun/dogfood/browser.rake`, headless, real turn; creds from `.env`.

---

## File Structure (created unless noted)

- **Auth:** `app/controllers/concerns/rbrun/authentication.rb`, `app/controllers/rbrun/auth/sessions_controller.rb`, `app/views/rbrun/auth/sessions/new.html.erb`, `app/views/layouts/rbrun/auth.html.erb`; modify `lib/rbrun/config.rb` (`validate!`), `lib/rbrun/engine.rb` (boot validate), `app/controllers/rbrun/application_controller.rb`.
- **Model machinery (modify):** `app/models/rbrun/session.rb`, `app/models/rbrun/session_message.rb`, `app/services/rbrun/agent_turn.rb`.
- **Helpers:** `app/helpers/rbrun/conversation_helper.rb` (markdown/tool_body/approval_actions/tools_validation_component).
- **Components:** `app/components/rbrun/conversation/{base,turn,timeline,segment}/component.rb` (+ `.html.erb` for base/turn/timeline/segment), `app/components/rbrun/conversation/tools_validation/{base.rb,default/component.rb,default/component.html.erb}`, `app/components/rbrun/conversation/commits/component.rb` (+ erb).
- **Controllers/jobs/views:** `messages_controller.rb`, `approvals_controller.rb`, `sessions_controller.rb`, `agent_turn_job.rb`, `approval_turn_job.rb`, `resume_turn_job.rb`, `app/views/rbrun/sessions/{show,index}.html.erb`, `app/views/rbrun/conversations/{_turn,_segment,_working,_approval_actions}.html.erb`, `app/views/rbrun/messages/{_form.html.erb,create.turbo_stream.erb}`, `app/views/layouts/rbrun/application.html.erb`, `config/routes.rb`.
- **JS:** `app/javascript/rbrun/controllers/{autoscroll,composer,sticky_details}_controller.js`, modify `app/javascript/rbrun/rbrun.js`; rebuild the bundle.
- **Dogfood:** `lib/tasks/rbrun/dogfood/browser.rake`.
- **Gems:** `rbrun.gemspec` — `redcarpet`.

---

### Task 1: Mandatory auth

**Interfaces:** `Rbrun.config.validate!` (raise unless auth configured); `Rbrun::Authentication` concern (`require_authentication`, `current_user`, `current_tenant`, `establish_session`, `reset`); `Rbrun::Auth::SessionsController` (`new`/`create`/`destroy`); routes `login`/`logout`.

- [ ] **Step 1: config validation (raise if no auth)**

In `lib/rbrun/config.rb`, add to the `Config` class:

```ruby
    # Auth is mandatory: at least one built-in user, or a host-supplied current_user resolver.
    def auth_configured? = users.any? || Rbrun.instance_variable_get(:@current_user_resolver)

    def validate!
      raise Rbrun::ConfigError, "rbrun requires auth: define at least one c.user (or set Rbrun.current_user_resolver)" unless auth_configured?
    end
```

In `lib/rbrun.rb` (`class << self`), add `attr_writer :current_user_resolver` and `def current_user_from(session) = @current_user_resolver&.call(session)`.

In `lib/rbrun/engine.rb`, validate after initializers:

```ruby
    config.after_initialize { Rbrun.config.validate! }
```

- [ ] **Step 2: the Authentication concern**

`app/controllers/concerns/rbrun/authentication.rb`:

```ruby
module Rbrun
  module Authentication
    extend ActiveSupport::Concern

    included do
      before_action :require_authentication
      helper_method :current_user, :current_tenant
    end

    private

    def current_user
      @current_user ||= (Rbrun.current_user_from(session) ||
                         (session[:rbrun_user_id] && Rbrun::User.find_by(id: session[:rbrun_user_id])))
    end

    def current_tenant = current_user&.tenant

    def require_authentication
      redirect_to rbrun.login_path unless current_user
    end

    def establish_session(user) = session[:rbrun_user_id] = user.id
    def reset_authentication = session.delete(:rbrun_user_id)
  end
end
```

- [ ] **Step 3: the login controller + views + routes + app controller**

`app/controllers/rbrun/application_controller.rb`:

```ruby
module Rbrun
  class ApplicationController < ActionController::Base
    include Rbrun::Authentication
    helper Rbrun::ComponentHelper
    helper Rbrun::ConversationHelper
    layout "rbrun/application"
  end
end
```

`app/controllers/rbrun/auth/sessions_controller.rb`:

```ruby
module Rbrun
  module Auth
    class SessionsController < Rbrun::ApplicationController
      layout "rbrun/auth"
      skip_before_action :require_authentication, only: %i[new create]

      def new; end

      def create
        user = Rbrun::User.find_by(email: params[:email].to_s.strip.downcase)
        if user&.authenticate(params[:password].to_s)
          establish_session(user)
          redirect_to rbrun.sessions_path
        else
          @error = "Invalid credentials."
          render :new, status: :unprocessable_entity
        end
      end

      def destroy
        reset_authentication
        redirect_to rbrun.login_path
      end
    end
  end
end
```

`app/views/rbrun/auth/sessions/new.html.erb`:

```erb
<div class="mx-auto mt-24 w-full max-w-sm">
  <%= component("card", title: "Sign in") do %>
    <% if @error %><p class="mb-3 text-sm text-red-600"><%= @error %></p><% end %>
    <%= form_with url: rbrun.login_path, method: :post, class: "flex flex-col gap-3" do %>
      <input type="email" name="email" placeholder="Email" autocomplete="email" autofocus
             class="rounded-md border border-slate-300 px-3 py-2 text-sm">
      <input type="password" name="password" placeholder="Password" autocomplete="current-password"
             class="rounded-md border border-slate-300 px-3 py-2 text-sm">
      <%= component("button", variant: :primary, type: "submit", full: true) do %>Sign in<% end %>
    <% end %>
  <% end %>
</div>
```

`app/views/layouts/rbrun/auth.html.erb`:

```erb
<!DOCTYPE html>
<html>
<head>
  <title>rbrun</title>
  <%= csrf_meta_tags %>
  <%= stylesheet_link_tag "rbrun/rbrun", "data-turbo-track": "reload" %>
</head>
<body class="bg-slate-50"><%= yield %></body>
</html>
```

`config/routes.rb`:

```ruby
Rbrun::Engine.routes.draw do
  get  "login",  to: "auth/sessions#new",     as: :login
  post "login",  to: "auth/sessions#create"
  delete "logout", to: "auth/sessions#destroy", as: :logout

  resources :sessions, path: "c", only: %i[index create show]
  post "c/:id",       to: "messages#create", as: :session_message
  post "c/:id/retry", to: "sessions#retry",  as: :session_retry
  resources :approvals, only: :update, param: :tool_use_id
end
```

- [ ] **Step 4: test + commit**

`test/controllers/rbrun/auth_test.rb` — an integration test (mount the engine in the dummy routes): unauthenticated `GET /rbrun/c` redirects to login; a valid `POST /rbrun/login` sets the session; boot raised without users is covered by a config unit test (`Rbrun.reset_config!; assert_raises(Rbrun::ConfigError) { Rbrun.config.validate! }`).

First **mount the engine** in `test/dummy/config/routes.rb`: `mount Rbrun::Engine => "/rbrun"`.

Run: `bin/rails test test/controllers/rbrun/auth_test.rb` → PASS.

```bash
git add app/controllers/concerns/rbrun app/controllers/rbrun lib/rbrun.rb lib/rbrun/config.rb lib/rbrun/engine.rb app/views/rbrun/auth app/views/layouts/rbrun/auth.html.erb config/routes.rb test/dummy/config/routes.rb test/controllers/rbrun/auth_test.rb
git commit -m "feat(ui): mandatory auth — Authentication concern + login controller + boot validation"
```

---

### Task 2: model machinery — broadcasts, turns, resume/continue, approval

**Interfaces:** `Session#{broadcast_event,segment_locals_for,turns,timeline,open_turn_lead,continue_turn!,resume_turn!}` + private `broadcast_status/broadcast_composer/broadcast_working`; `SessionMessage#{decide_approval!,run_frozen_call!,visible?,broadcastable?,finalized?}` + broadcast callbacks + `RENDERED_EVENTS`/`BROADCAST_EVENTS`; `AgentTurn#{continue,resume}` + `resume_prompt` + `internal` rows.

- [ ] **Step 1: `SessionMessage`** — add:

```ruby
    RENDERED_EVENTS  = %w[text tool_use tool_result internal].freeze
    BROADCAST_EVENTS = %w[text tool_use tool_result internal].freeze

    after_create_commit :broadcast_open_or_event, if: :broadcastable?
    after_update_commit :broadcast_finalized_event, if: :finalized?

    def visible? = event_type.in?(RENDERED_EVENTS) || (event_type.nil? && role.in?(%w[user assistant]))

    def decide_approval!(decision)
      status = decision.to_s == "refuse" ? "rejected" : "approved"
      claimed = self.class.where(id: id, approval_status: "pending")
                    .update_all(approval_status: status, updated_at: Time.current)
      return nil if claimed.zero?

      reload
      approval_rejected? ? refusal_nudge : run_frozen_call!
    end

    private

    def run_frozen_call!
      name = payload["name"]
      tool = Rbrun::ApplicationTool.find(name)
      args = (payload["input"] || {}).symbolize_keys
      result = begin
        tool ? tool.in_session(session).execute(**args) : { "error" => "unknown tool: #{name}" }
      rescue StandardError => e
        { "error" => e.message }
      end
      failed = result.is_a?(Hash) && result["error"]
      session.messages.create!(role: "tool", event_type: "tool_result", content: result.to_json,
        tool_use_id: tool_use_id,
        payload: { "tool_use_id" => tool_use_id, "result" => result, "is_error" => !!failed })
      "The user approved #{name}. Result: #{result.to_json}. Continue."
    end

    def refusal_nudge = "The user refused #{payload['name']}. Do not retry it; propose an alternative."

    def broadcastable? = role == "user" || event_type.in?(BROADCAST_EVENTS)
    def finalized? = visible? && saved_change_to_content? && content.present?

    def broadcast_open_or_event
      if role == "user" && event_type == "text"
        Turbo::StreamsChannel.broadcast_append_to("rbrun_session_#{session_id}",
          target: "conversation_#{session_id}", partial: "rbrun/conversations/turn",
          locals: { user_message: self, messages: [ self ] })
      else
        session.broadcast_event(self, created: true)
      end
    end

    def broadcast_finalized_event = session.broadcast_event(self, created: false)
```

- [ ] **Step 2: `Session`** — add `broadcast_event`/`segment_locals_for`/`timeline`/`turns`/`open_turn_lead`, `continue_turn!`/`resume_turn!` (mirror `run_turn`), and the private `broadcast_status`/`broadcast_composer`/`broadcast_working` (no rating, no artifacts region). Add `after_update_commit :broadcast_status, if: :saved_change_to_status?`. The commit pane broadcast: after `record_commits!`, `broadcast_replace_to "rbrun_session_#{id}", target: "commits_#{id}", partial: "rbrun/conversations/commits"` (Task 6). Keep the Phase 6 `run_turn` (it also records commits); wrap the `working!…done!/failed!` body identically in `continue_turn!`/`resume_turn!` calling `turn.continue(nudge)` / `turn.resume`.

- [ ] **Step 3: `AgentTurn`** — add `continue(nudge)` and `resume`: log an `internal` row, then `call_client(nudge)` / `call_client(resume_prompt)` without a user row; `resume_prompt` restates the last user message. `call_client` = the existing `run`'s runtime call factored so `run`/`continue`/`resume` share it.

- [ ] **Step 4: tests + commit** — unit-test with the FakeRuntime pattern (DI): a gated turn then `decide_approval!("approve")` runs the frozen tool and logs a `tool_result`; `turns`/`timeline` group correctly; `broadcast_event` is exercised via the segment computation (Task 4 covers rendering). Run `bin/rails test test/models/rbrun`.

```bash
git commit -am "feat(ui): Session/SessionMessage broadcast engine + AgentTurn continue/resume + approval execution"
```

---

### Task 3: conversation helpers

`app/helpers/rbrun/conversation_helper.rb` — `markdown(text)` (Redcarpet, safe render), `tool_body(data)` (pretty JSON), `approval_actions(tool_use_id)` (render `rbrun/conversations/approval_actions`), `tools_validation_component(name)` (→ `Rbrun::Conversation::ToolsValidation::Default::Component` — rbrun keeps one fallback card; hosts add their own). Add `redcarpet` to the gemspec. Test: `markdown("**x**")` → `<strong>`; `tool_body({"a"=>1})` → pretty JSON.

```bash
git commit -am "feat(ui): conversation helpers — markdown, tool_body, approval_actions, tools_validation"
```

---

### Task 4: conversation ViewComponents

Build `base`/`turn`/`timeline`/`segment` (+ erb) + `tools_validation/{base,default}` as `Rbrun::Conversation::*::Component < Rbrun::ApplicationViewComponent`, with these details:
- Namespace `Rbrun::Conversation::`; the aggregate is `session`, driving `session.id`/`session.working?`/`session.turns`.
- **turn component:** renders prose only — no `attachments`, `artifacts`, or `rating` renders; the header uses `<%= lucide_icon("sparkles", class: "size-5 text-default-600") %>`.
- **base component:** `turbo_stream_from "rbrun_session_#{session.id}"`; keep the autoscroll viewport + `#conversation_<id>` + `#composer`; render `messages/form`. Append a `<div id="commits_<id>">` region (the commit pane, Task 6).
- **segment/timeline:** the segment computation (`segments`/`results`/`open_at?`/`anchor?`/`segment_index_for`/`dom_id_for`/`steps`/`APPROVAL_BADGES`/`tool_hint`); `helpers.markdown`/`lucide_icon`/`class_names`/`pluralize`/`number_to_human_size`/`tool_body`/`tools_validation_component`/`approval_actions` resolve from Task 3 + lucide-rails + Rails.
- Components use plain `def initialize(...)` + `attr_reader` (no `option`), subclassing the DSL base only for `component()` + `erb_template`/sidecar.
- The `_turn.html.erb`/`_segment.html.erb` partials render the components directly (no `preset(...)` indirection).

Test (`test/components/rbrun/timeline_test.rb`): build a `Session` + `SessionMessage` rows (user text, an assistant text, a tool_use + tool_result pair, a pending gate) and `render_inline` the `Timeline` — assert a prose block, a "1 action"/"2 actions" accordion, the tool name, and the approval form on the pending gate. Then `bin/rails test test/components`.

```bash
git commit -am "feat(ui): conversation components — base, turn, timeline, segment, tools_validation"
```

---

### Task 5: controllers, jobs, routes, form, layout, pages

- **Jobs** (3 thin): `AgentTurnJob#perform(session_id, content)` → `Session.find(session_id).run_turn(content)`; `ApprovalTurnJob#perform(session_id, nudge)` → `continue_turn!(nudge)`; `ResumeTurnJob#perform(session_id)` → `resume_turn!`.
- **MessagesController#create** (port; drop attachments): `AgentTurnJob.perform_later(@session.id, content)`, `respond_to { turbo_stream / html redirect }`; `set_session` scopes `Rbrun::Session.for_tenant(current_tenant).find`.
- **ApprovalsController#update** (port verbatim, `chat`→`session`, tenant scope on `current_tenant`).
- **SessionsController** `index` (list `Session.for_tenant(current_tenant)`), `create` (needs a Worktree — for the dogfood/demo, create/find a default Worktree for the tenant, then `worktree.sessions.create!`; redirect to show), `show` (`@session`), `retry` (`ResumeTurnJob`).
- **`messages/_form.html.erb`** (port, strip attachments/paperclip; keep the failed-turn banner + Réessayer → `session_retry_path`, textarea, send/spinner), **`messages/create.turbo_stream.erb`** (replace `new_message`).
- **`layouts/rbrun/application.html.erb`** — loads `rbrun/rbrun` css + js (`javascript_include_tag "rbrun/rbrun", type: "module"`), a header with logout, `<%= yield %>`.
- **`sessions/show.html.erb`** — `render Rbrun::Conversation::Default::Component.new(session: @session)` (or Base directly); **`sessions/index.html.erb`** — the session cards.

Test: a controller/integration test — signed-in `POST /rbrun/c/:id` enqueues `AgentTurnJob` (assert_enqueued_with) and returns turbo_stream; `PATCH /rbrun/approvals/:tool_use_id` on a pending row decides it + enqueues `ApprovalTurnJob`. `bin/rails test test/controllers`.

```bash
git commit -am "feat(ui): controllers + jobs + routes + composer form + layout + session pages"
```

---

### Task 6: Stimulus controllers, JS bundle, commit pane

- Copy `autoscroll_controller.js`, `composer_controller.js` (strip the attachment/DataTransfer code — no uploads), `sticky_details_controller.js` verbatim into `app/javascript/rbrun/controllers/`.
- `app/javascript/rbrun/rbrun.js` registers them: `import Autoscroll from "./controllers/autoscroll_controller"; application.register("autoscroll", Autoscroll)` (and composer, sticky-details).
- **Commit pane:** `Rbrun::Conversation::Commits::Component.new(session:)` + erb — lists `session.commits` (sha + message) in a card, rendered in the base component's `#commits_<id>` region; `Session` broadcasts a replace of it after `record_commits!`.
- Rebuild: `bun run build`; commit the built `app/assets/builds/rbrun/rbrun.js`.

Test: `render_inline` the Commits component with a session that has commits → asserts the shas. `bin/rails test`.

```bash
git commit -am "feat(ui): Stimulus controllers (autoscroll/composer/sticky_details) + commit pane; rebuild bundle"
```

---

### Task 7: Dogfood — a real conversation in a headless browser

`lib/tasks/rbrun/dogfood/browser.rake` — boot the dummy (or use `Capybara`/`cuprite` if available; else drive via HTTP + assert the persisted log). Sign in as the seeded dev user, create a session under a worktree, post a message that calls the `identity` + a demo tool, and assert (from the DB + the rendered page): the user turn appended, the assistant prose rendered, the tools accordion has the call, status landed `done`. Creds from `.env`. If no headless browser is available, fall back to an integration-style drive (`ActionDispatch::IntegrationTest` session) asserting the streamed rows + a `GET /rbrun/c/:id` render.

Run: `bin/rails app:dogfood:browser`. Full verification: `bin/rails test`, `bin/rubocop`, both gem suites, `bun run build`.

```bash
git commit -am "feat(dogfood): browser — a real conversation renders end to end (Phase 8 gate)"
```

---

## Self-Review

**1. Spec coverage (Phase 8 contract):** MessagesController/ApprovalsController + atomic `decide_approval!` + job-resume (Tasks 2,5) ✓; 3 jobs (5) ✓; broadcast engine append/replace + `segment_locals_for` + `broadcast_status`/`composer`/`working` + coalesced tokens (2) ✓; timeline/segment/turn/base components on Phase 7 primitives (4) ✓; 3 Stimulus controllers (6) ✓; routes + login (mandatory auth) (1,5) ✓; Worktree commit pane (6) ✓; mounted in test/dummy (1) ✓; browser dogfood (7) ✓.

**2. Placeholder scan:** Tasks specify concrete components and behaviours with named structural choices (the `Session` aggregate, the `Rbrun::Conversation::` namespace, no artifacts/rating/attachments) — not placeholders. New code (auth, helpers, commit pane, config validate) is given in full.

**3. Type/name consistency:** `rbrun_session_<id>` stream everywhere; `Session#broadcast_event(msg, created:)`/`segment_locals_for`/`turns`; `SessionMessage#decide_approval!`/`run_frozen_call!` (uses `ApplicationTool.find` + `in_session`); `Rbrun::Conversation::*::Component`; `current_tenant = current_user.tenant`; routes `login`/`sessions`/`approvals` match the controllers.

**Risk areas:** ViewComponent rendering with the helper chain (markdown/lucide/tool_body); Turbo broadcast wiring under the async cable adapter in test/dev; the headless-browser dogfood (fallback: integration-test drive). Validated by the component render tests, the controller/integration tests, and the dogfood.

**This is the final phase — after it, all 8 are done.**
