# Skill Editor — Plan 1: the form + versions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A vanilla Rails form to author/edit a skill — fields ⇄ `SKILL.md`, Save promotes a new `SkillVersion` — plus a `sessions.kind` tag so machine-driven runs stay out of the conversation index.

**Architecture:** A pure `Rbrun::SkillForm` service is the one seam that assembles a `SKILL.md` (YAML frontmatter + markdown body) from the editor's fields and parses one back. The archive (`SkillVersion.archive`) stays the single source of a skill's content — the form only (de)serializes its `SKILL.md`; create packs a v1, update merges the edited `SKILL.md` onto the base version's other files and `promote!`s a new version. The form view is composed entirely from `Rbrun::Ui::*` primitives via `component(...)`. A `kind` enum on `Session` (default `:user`) lets the conversation index filter out non-user sessions.

**Tech Stack:** Rails 8.1 engine, Ruby 3.4.4, ViewComponent primitives, `component(...)`/`custom(...)` helpers, `YAML`, `Rbrun::SkillArchive`.

## Global Constraints

- **Reach every component through `component("<name>", …)`** (flat `Rbrun::Ui::*` primitives) or `custom("folder/name", …)` — NEVER `render(Rbrun::…::Component.new)` in a view, NEVER a raw `<input>`/`<select>`/`<textarea>`/`<button>`. (CLAUDE.md, non-negotiable.)
- **The versioned archive is the only source of a skill's content.** Card/soft-hint data lives INSIDE `SKILL.md` in the archive — NEVER a column on `Skill`. Load parses the selected version's archive; Save assembles `SKILL.md` and `promote!`s.
- **Do not swallow errors** — let them raise; the UI surfaces them via flash / re-render.
- Every engine record is tenant-scoped (`Rbrun::Tenanted`, `for_tenant`); the controller uses `current_tenant`.
- Engine migrations live in `db/migrate/` (timestamped); after adding one run `bin/rails db:migrate` to update `test/dummy/db/schema.rb`.
- Test suite: `bin/rails test`. Single file: `bin/rails test test/…`. Lint: `bin/rubocop -a`.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

### Task 1: `sessions.kind` enum + conversation-index filter

**Files:**
- Create: `db/migrate/20260723200000_add_kind_to_rbrun_sessions.rb`
- Modify: `app/models/rbrun/session.rb` (add enum)
- Modify: `app/controllers/rbrun/sessions_controller.rb:8-15` (filter index to `:user`)
- Test: `test/models/rbrun/session_test.rb`, `test/controllers/rbrun/sessions_flow_test.rb`

**Interfaces:**
- Produces: `Session#kind` enum `{ user: "user", skill_scenario: "skill_scenario" }`, default `"user"`; the conversation index (`SessionsController#index`) returns only `kind: "user"` sessions. Plan 2's `SkillScenarioRun` will create `:skill_scenario` sessions.

- [ ] **Step 1: Write the failing model test**

Add to `test/models/rbrun/session_test.rb` (inside the existing `Rbrun::SessionTest`):

```ruby
test "kind defaults to :user and skill_scenario is a valid kind" do
  wt = Rbrun::Worktree.create!(tenant: "acme", repo: "a/b")
  session = wt.sessions.create!
  assert session.user?
  assert_equal "user", session.kind

  scenario = wt.sessions.create!(kind: :skill_scenario)
  assert scenario.skill_scenario?
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/models/rbrun/session_test.rb -n "/kind defaults/"`
Expected: FAIL — `NoMethodError: undefined method 'user?'` (no `kind` yet).

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260723200000_add_kind_to_rbrun_sessions.rb`:

```ruby
class AddKindToRbrunSessions < ActiveRecord::Migration[8.1]
  # A Session's durable identity: :user (a person's conversation) vs machine-driven kinds
  # (:skill_scenario — a self-validating run). `auto` stays the runtime lever; `kind` is "what is this".
  def change
    add_column :rbrun_sessions, :kind, :string, default: "user", null: false
    add_index  :rbrun_sessions, :kind
  end
end
```

- [ ] **Step 4: Add the enum to the model**

In `app/models/rbrun/session.rb`, after the `status` enum (around line 22), add:

```ruby
    # Durable "what is this session": a person's conversation vs a machine-driven run. The conversation
    # index shows only :user; :skill_scenario is a self-validating run (Plan 2). Kept open for more kinds.
    enum :kind, { user: "user", skill_scenario: "skill_scenario" }, default: "user"
```

- [ ] **Step 5: Migrate and run the model test**

Run: `bin/rails db:migrate && bin/rails test test/models/rbrun/session_test.rb -n "/kind defaults/"`
Expected: PASS. Verify `test/dummy/db/schema.rb` now shows `t.string "kind", default: "user", null: false` on `rbrun_sessions`.

- [ ] **Step 6: Write the failing index-filter test**

Add to `test/controllers/rbrun/sessions_flow_test.rb` (a request test — mirror its existing setup for login + a repo/worktree; if it already has a `setup` that logs in and sets a `current_repo`, reuse it):

```ruby
test "the conversation index excludes skill_scenario sessions" do
  wt = Rbrun::Worktree.for_tenant("rbrun").create!(repo: current_repo_for_test)
  human   = wt.sessions.create!(kind: :user)
  machine = wt.sessions.create!(kind: :skill_scenario)

  get "/rbrun/c"
  assert_response :success
  assert_select "a[href=?]", "/rbrun/c/#{human.id}"
  assert_select "a[href=?]", "/rbrun/c/#{machine.id}", count: 0
end
```

Note: `current_repo_for_test` stands for whatever repo the flow test's session index is scoped to — read the existing `sessions_flow_test.rb` setup and use that exact repo string (the index is scoped by `current_repo`). If the existing test picks a repo via a helper, reuse it verbatim.

- [ ] **Step 7: Run it to verify it fails**

Run: `bin/rails test test/controllers/rbrun/sessions_flow_test.rb -n "/excludes skill_scenario/"`
Expected: FAIL — the machine session's link is present (no filter yet).

- [ ] **Step 8: Filter the index**

In `app/controllers/rbrun/sessions_controller.rb`, change the `current_repo` branch of `index` to add `.where(kind: "user")`:

```ruby
    def index
      @sessions =
        if current_repo
          Rbrun::Session.for_tenant(current_tenant)
                        .joins(:worktree).where(rbrun_worktrees: { repo: current_repo })
                        .where(kind: "user")
                        .order(created_at: :desc)
        else
          Rbrun::Session.none
        end
    end
```

- [ ] **Step 9: Run both tests + the full session/flow suites**

Run: `bin/rails test test/models/rbrun/session_test.rb test/controllers/rbrun/sessions_flow_test.rb`
Expected: PASS (no regressions).

- [ ] **Step 10: Commit**

```bash
git add db/migrate/20260723200000_add_kind_to_rbrun_sessions.rb app/models/rbrun/session.rb \
        app/controllers/rbrun/sessions_controller.rb test/models/rbrun/session_test.rb \
        test/controllers/rbrun/sessions_flow_test.rb test/dummy/db/schema.rb
git commit -m "feat(sessions): kind enum (user|skill_scenario), index shows only :user

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `Rbrun::SkillForm` — fields ⇄ `SKILL.md`

**Files:**
- Create: `app/services/rbrun/skill_form.rb`
- Test: `test/services/rbrun/skill_form_test.rb`

**Interfaces:**
- Consumes: `Rbrun::SkillArchive.files(blob)` (→ `{ "SKILL.md" => bytes, … }`).
- Produces:
  - `Rbrun::SkillForm.new(attrs = {})` — `attrs` a Hash / permitted params with keys `name label tagline icon kind example description body preferred_skills preferred_tools`. Scalar keys → `String`; `preferred_skills`/`preferred_tools` → `Array<String>` (blanks rejected). Exposes an accessor per field.
  - `#skill_md → String` — the assembled `SKILL.md` (YAML frontmatter with only non-blank keys, then the body).
  - `Rbrun::SkillForm.parse(md) → SkillForm` — fields filled from a `SKILL.md`'s frontmatter + body.
  - `Rbrun::SkillForm.from_version(version) → SkillForm` — parse a `SkillVersion`'s archived `SKILL.md` (nil version → an empty form).

- [ ] **Step 1: Write the failing round-trip test**

Create `test/services/rbrun/skill_form_test.rb`:

```ruby
require "test_helper"

module Rbrun
  class SkillFormTest < ActiveSupport::TestCase
    test "assemble → parse is a round-trip across every field" do
      form = Rbrun::SkillForm.new(
        name: "Changelog", label: "Changelog writer", tagline: "Ship notes, fast",
        icon: "scroll", kind: "artifact", example: "summarize what shipped this week",
        description: "Turn merged PRs into a human changelog.",
        body: "# Changelog\n\nDo the thing.\n",
        preferred_skills: %w[create-skill], preferred_tools: %w[save_artifact validate_step]
      )

      parsed = Rbrun::SkillForm.parse(form.skill_md)

      assert_equal "Changelog", parsed.name
      assert_equal "Changelog writer", parsed.label
      assert_equal "Ship notes, fast", parsed.tagline
      assert_equal "scroll", parsed.icon
      assert_equal "artifact", parsed.kind
      assert_equal "summarize what shipped this week", parsed.example
      assert_equal "Turn merged PRs into a human changelog.", parsed.description
      assert_equal %w[create-skill], parsed.preferred_skills
      assert_equal %w[save_artifact validate_step], parsed.preferred_tools
      assert_includes parsed.body, "# Changelog"
      assert_includes parsed.body, "Do the thing."
    end

    test "blank scalar keys and empty lists are omitted from the frontmatter" do
      md = Rbrun::SkillForm.new(name: "Bare", body: "just a body").skill_md
      assert_includes md, "name: Bare"
      refute_includes md, "label:"
      refute_includes md, "tagline:"
      refute_includes md, "preferred_skills:"
      refute_includes md, "preferred_tools:"
    end

    test "list fields reject blank entries (the multi_select hidden \"\" is dropped)" do
      form = Rbrun::SkillForm.new(name: "X", preferred_skills: [ "", "create-skill", "" ])
      assert_equal %w[create-skill], form.preferred_skills
    end

    test "from_version parses the archived SKILL.md; nil version is an empty form" do
      md    = Rbrun::SkillForm.new(name: "Packed", description: "d", body: "b").skill_md
      files = { "SKILL.md" => md, "reference.md" => "resource" }
      skill = Rbrun::Skill.create!(tenant: "acme", slug: "packed", name: "Packed")
      version = skill.promote!(digest: Rbrun::SkillArchive.digest_files(files),
                               archive: Rbrun::SkillArchive.pack_files(files), source: :ui)

      form = Rbrun::SkillForm.from_version(version)
      assert_equal "Packed", form.name
      assert_equal "d", form.description
      assert_includes form.body, "b"

      assert_equal "", Rbrun::SkillForm.from_version(nil).name
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/services/rbrun/skill_form_test.rb`
Expected: FAIL — `uninitialized constant Rbrun::SkillForm`.

- [ ] **Step 3: Implement `Rbrun::SkillForm`**

Create `app/services/rbrun/skill_form.rb`:

```ruby
require "yaml"

module Rbrun
  # Fields ⇄ SKILL.md. The ONE seam that assembles a SKILL.md (YAML frontmatter + markdown body) from
  # the editor's fields and parses one back. The archive (SkillVersion#archive) stays the source of a
  # skill's content — this only (de)serializes its SKILL.md. Card + soft-hint keys live in the
  # frontmatter, NEVER in a column on Skill.
  class SkillForm
    # Scalar frontmatter/body fields, in frontmatter emit order (body is handled separately).
    FRONT_KEYS  = %i[name description label tagline icon kind example].freeze
    LIST_KEYS   = %i[preferred_skills preferred_tools].freeze
    SCALAR_KEYS = (FRONT_KEYS + %i[body]).freeze

    attr_accessor(*SCALAR_KEYS, *LIST_KEYS)

    def initialize(attrs = {})
      h = attrs.respond_to?(:to_unsafe_h) ? attrs.to_unsafe_h : attrs.to_h
      h = h.symbolize_keys
      SCALAR_KEYS.each { |k| public_send("#{k}=", h[k].to_s) }
      LIST_KEYS.each   { |k| public_send("#{k}=", Array(h[k]).map(&:to_s).map(&:strip).reject(&:blank?)) }
    end

    # The assembled SKILL.md: frontmatter (only non-blank keys) then the body.
    def skill_md = "#{frontmatter}\n\n#{body.to_s.strip}\n"

    # Parse a SKILL.md string back into a form (frontmatter → fields, remainder → body).
    def self.parse(md)
      front, body = split(md)
      data = front.present? ? (YAML.safe_load(front) || {}) : {}
      new(data.merge("body" => body.to_s.strip))
    end

    # Parse a SkillVersion's archived SKILL.md. A nil version yields an empty form (the New form).
    def self.from_version(version)
      return new if version.nil?

      md = Rbrun::SkillArchive.files(version.archive)["SKILL.md"].to_s
      parse(md)
    end

    # Split "---\n<frontmatter>\n---\n<body>" → [frontmatter, body]. No fence ⇒ ["", whole string].
    def self.split(md)
      if (m = md.to_s.match(/\A---\s*\n(.*?)\n---\s*\n?(.*)\z/m))
        [ m[1], m[2] ]
      else
        [ "", md.to_s ]
      end
    end
    private_class_method :split

    private

      def frontmatter
        h = {}
        FRONT_KEYS.each { |k| v = public_send(k); h[k.to_s] = v if v.present? }
        LIST_KEYS.each  { |k| v = public_send(k); h[k.to_s] = v if v.any? }
        yaml = YAML.dump(h).delete_prefix("---\n").strip
        "---\n#{yaml}\n---"
      end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/services/rbrun/skill_form_test.rb`
Expected: PASS (all four tests).

- [ ] **Step 5: Commit**

```bash
git add app/services/rbrun/skill_form.rb test/services/rbrun/skill_form_test.rb
git commit -m "feat(skills): SkillForm — fields ⇄ SKILL.md (archive stays the truth)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: routes + `SkillsController` new/create/edit/update + the form view

**Files:**
- Modify: `config/routes.rb` (resourceful skills + keep `reconcile`; rename the drawer route)
- Modify: `app/controllers/rbrun/skills_controller.rb` (add `new`/`create`/`edit`/`update`, `form_params`, option helpers)
- Create: `app/views/rbrun/skills/new.html.erb`
- Create: `app/views/rbrun/skills/edit.html.erb`
- Create: `app/views/rbrun/skills/_form.html.erb`
- Create: `app/views/rbrun/skills/_version_picker.html.erb`
- Modify: `app/views/rbrun/skills/index.html.erb` (point "New skill" at the form)
- Test: `test/controllers/rbrun/skills_flow_test.rb`

**Interfaces:**
- Consumes: `Rbrun::SkillForm` (Task 2); `Skill#promote!(digest:, archive:, source:)`; `Rbrun::SkillArchive.{files,pack_files,digest_files}`; `Rbrun::ApplicationTool.manifest`.
- Produces: routes `new_skill`, `skill` (create/update), `edit_skill`, `reconcile_skill`; `SkillsController` actions; the form partials.

- [ ] **Step 1: Write the failing controller tests**

Read the existing `test/controllers/rbrun/skills_flow_test.rb` for its login/tenant setup and reuse it. Add:

```ruby
test "GET new renders an empty skill form" do
  get "/rbrun/skills/new"
  assert_response :success
  assert_select "form[action=?][method=post]", "/rbrun/skills"
  assert_select "input[name=?]", "skill[name]"
  assert_select "textarea[name=?]", "skill[body]"
end

test "POST skills creates a skill with a v1 assembled from the form" do
  assert_difference("Rbrun::Skill.count", 1) do
    post "/rbrun/skills", params: { skill: {
      name: "Changelog", label: "Changelog writer", description: "PRs → notes",
      body: "# Changelog\n\nDo it.", preferred_skills: [ "", "create-skill" ], preferred_tools: [ "" ]
    } }
  end
  skill = Rbrun::Skill.for_tenant("rbrun").find_by!(slug: "changelog")
  assert_equal "Changelog", skill.name
  assert skill.current_version.present?
  assert_equal "ui", skill.current_version.source
  md = Rbrun::SkillArchive.files(skill.current_version.archive)["SKILL.md"]
  assert_includes md, "name: Changelog"
  assert_includes md, "# Changelog"
  assert_redirected_to "/rbrun/skills/changelog/edit"
end

test "GET edit loads the current version's fields" do
  skill = create_ui_skill("editme", name: "Edit Me", body: "original body")
  get "/rbrun/skills/editme/edit"
  assert_response :success
  assert_select "input[name=?][value=?]", "skill[name]", "Edit Me"
  assert_select "textarea[name=?]", "skill[body]", text: /original body/
end

test "PATCH skills promotes a new version, preserving the base version's other files" do
  skill = create_ui_skill("editme", name: "Edit Me", body: "v1 body",
                           extra: { "reference.md" => "keep me" })
  assert_difference("skill.versions.count", 1) do
    patch "/rbrun/skills/editme", params: { skill: { name: "Edit Me", body: "v2 body" } }
  end
  skill.reload
  files = Rbrun::SkillArchive.files(skill.current_version.archive)
  assert_includes files["SKILL.md"], "v2 body"
  assert_equal "keep me", files["reference.md"], "non-SKILL.md files survive an edit"
  assert_redirected_to "/rbrun/skills/editme/edit"
end

test "GET edit?version= loads that specific version into the form" do
  skill = create_ui_skill("editme", name: "Edit Me", body: "v1 body")
  v1 = skill.current_version
  patch "/rbrun/skills/editme", params: { skill: { name: "Edit Me", body: "v2 body" } }

  get "/rbrun/skills/editme/edit", params: { version: v1.id }
  assert_response :success
  assert_select "textarea[name=?]", "skill[body]", text: /v1 body/
end

test "POST skills with a taken slug re-renders new with an error (no clobber)" do
  create_ui_skill("changelog", name: "Changelog", body: "b")
  assert_no_difference("Rbrun::Skill.count") do
    post "/rbrun/skills", params: { skill: { name: "Changelog", body: "dupe" } }
  end
  assert_response :unprocessable_entity
end
```

Add this helper at the bottom of the test class:

```ruby
private

  # A skill whose current version is a UI-authored SKILL.md (+ optional extra files).
  def create_ui_skill(slug, name:, body:, extra: {})
    skill = Rbrun::Skill.create!(tenant: "rbrun", slug:, name:)
    md    = Rbrun::SkillForm.new(name:, body:).skill_md
    files = { "SKILL.md" => md }.merge(extra)
    skill.promote!(digest: Rbrun::SkillArchive.digest_files(files),
                   archive: Rbrun::SkillArchive.pack_files(files), source: :ui)
    skill
  end
```

Note: use whatever tenant the existing `skills_flow_test.rb` logs in as (it is `"rbrun"` for the dev login `dev@rbrun.test`; confirm against the file and adjust the strings if it differs).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/rbrun/skills_flow_test.rb -n "/new|create|edit|PATCH|version|taken/"`
Expected: FAIL — no `new`/`create`/`edit`/`update` routes/actions yet.

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, replace the three manual skill lines:

```ruby
  # Skills panel: list + the authoring form (new/create/edit/update) + reconcile a divergence.
  resources :skills, param: :slug, only: %i[index new create edit update] do
    member { post :reconcile }
  end
  # The AI-assisted create-skill drawer conversation (kept until in-form authoring absorbs it).
  post "skills/new_conversation", to: "skills#build", as: :build_skill
```

(This drops the old `get "skills"` / `post "skills/new"` / `post "skills/:slug/reconcile"` lines — the resourceful block re-provides `skills_path` and `reconcile_skill_path`.)

- [ ] **Step 4: Add the controller actions**

In `app/controllers/rbrun/skills_controller.rb`, add the actions above `private` and the helpers below it. Keep `index`, `build`, `reconcile` as they are.

```ruby
    def new
      @skill = nil
      @form  = Rbrun::SkillForm.new
    end

    def create
      @form = Rbrun::SkillForm.new(form_params)
      slug  = @form.name.to_s.parameterize
      if slug.blank?
        flash.now[:alert] = "A skill needs a name."
        @skill = nil
        return render :new, status: :unprocessable_entity
      end

      skill = Rbrun::Skill.new(tenant: current_tenant, slug:, name: @form.name)
      files = { "SKILL.md" => @form.skill_md }
      skill.save!
      skill.promote!(digest: Rbrun::SkillArchive.digest_files(files),
                     archive: Rbrun::SkillArchive.pack_files(files), source: :ui)
      redirect_to rbrun.edit_skill_path(skill.slug), notice: "Skill created."
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      @skill = nil
      flash.now[:alert] = "Couldn't create the skill: #{e.message}"
      render :new, status: :unprocessable_entity
    end

    def edit
      @skill   = find_skill
      @version = params[:version].present? ? @skill.versions.find(params[:version]) : @skill.current_version
      @form    = Rbrun::SkillForm.from_version(@version)
    end

    def update
      @skill = find_skill
      @form  = Rbrun::SkillForm.new(form_params)
      base   = @skill.current_version ? Rbrun::SkillArchive.files(@skill.current_version.archive) : {}
      files  = base.merge("SKILL.md" => @form.skill_md)

      @skill.update!(name: @form.name.presence || @skill.name)
      @skill.promote!(digest: Rbrun::SkillArchive.digest_files(files),
                      archive: Rbrun::SkillArchive.pack_files(files), source: :ui)
      redirect_to rbrun.edit_skill_path(@skill.slug), notice: "New version promoted."
    end
```

Then in the `private` section add:

```ruby
      def find_skill
        Rbrun::Skill.for_tenant(current_tenant).find_by!(slug: params[:slug])
      end

      def form_params
        params.require(:skill).permit(:name, :label, :tagline, :icon, :kind, :example,
                                      :description, :body, preferred_skills: [], preferred_tools: [])
      end

      # Soft-hint options (author/display only). Skills = the tenant's slugs; tools = the tool manifest.
      def skill_options = Rbrun::Skill.for_tenant(current_tenant).order(:slug).pluck(:name, :slug)
      def tool_options  = Rbrun::ApplicationTool.manifest.map { |t| [ t["name"], t["name"] ] }
```

- [ ] **Step 5: Create the shared form partial**

Create `app/views/rbrun/skills/_form.html.erb` (composed ONLY from primitives via `component(...)`):

```erb
<%# locals: skill (nil for new), form (Rbrun::SkillForm), skill_options, tool_options %>
<%= component("surface", title: skill ? "Edit skill" : "New skill", heading: :h1, inset: :centered) do |s| %>
  <% if skill && skill.versions.many? %>
    <% s.with_actions do %>
      <%= render "rbrun/skills/version_picker", skill:, form: %>
    <% end %>
  <% end %>

  <% s.with_body do %>
    <% if flash[:alert] %>
      <div class="mb-4 rounded-lg border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-700"><%= flash[:alert] %></div>
    <% end %>

    <%= form_with url: (skill ? rbrun.skill_path(skill.slug) : rbrun.skills_path),
                  method: (skill ? :patch : :post), class: "flex flex-col gap-8" do %>

      <%= component("form_section", title: "Identity", columns: 2) do %>
        <%= component("field", label: "Name",       name: "skill[name]",    value: form.name) %>
        <%= component("field", label: "Label",      name: "skill[label]",   value: form.label,   required: false) %>
        <%= component("field", label: "Tagline",    name: "skill[tagline]", value: form.tagline, required: false) %>
        <%= component("field", label: "Icon",       name: "skill[icon]",    value: form.icon,    required: false) %>
        <%= component("field", label: "Kind",       name: "skill[kind]",    value: form.kind,    required: false) %>
        <%= component("field", label: "Example ask", name: "skill[example]", value: form.example, required: false) %>
      <% end %>

      <%= component("form_section", title: "Description") do %>
        <%= component("textarea", label: "Description", name: "skill[description]", value: form.description, rows: 3) %>
      <% end %>

      <%= component("form_section", title: "Instructions") do %>
        <%= component("textarea", label: "SKILL.md body", name: "skill[body]", value: form.body, rows: 16) %>
      <% end %>

      <%= component("form_section", title: "Soft hints", description: "Author-only nudges — display, not runtime injection.", columns: 2) do %>
        <%= component("multi_select", label: "Preferred skills", name: "skill[preferred_skills]",
              options: skill_options, selected: form.preferred_skills) %>
        <%= component("multi_select", label: "Preferred tools", name: "skill[preferred_tools]",
              options: tool_options, selected: form.preferred_tools) %>
      <% end %>

      <div class="flex justify-end">
        <%= component("button", type: "submit", variant: :primary) do %>
          <%= skill ? "Save new version" : "Create skill" %>
        <% end %>
      </div>
    <% end %>
  <% end %>
<% end %>
```

- [ ] **Step 6: Create the version picker partial**

Create `app/views/rbrun/skills/_version_picker.html.erb` (plain GET form + a Load submit — no JS):

```erb
<%# locals: skill, form. A GET to edit with ?version= reloads the form from that version. %>
<%= form_with url: rbrun.edit_skill_path(skill.slug), method: :get, class: "flex items-end gap-2" do %>
  <%= component("select", label: "Version", name: "version", include_blank: false,
        value: (params[:version].presence || skill.current_version_id),
        options: skill.versions.order(created_at: :desc).map { |v|
          [ "#{v.created_at.to_fs(:short)} · #{v.source} · #{v.digest.first(7)}", v.id ]
        }) %>
  <%= component("button", type: "submit", variant: :white, size: :sm) { "Load" } %>
<% end %>
```

- [ ] **Step 7: Create the `new` and `edit` templates**

Create `app/views/rbrun/skills/new.html.erb`:

```erb
<%= render "rbrun/skills/form", skill: nil, form: @form,
      skill_options:, tool_options: %>
```

Create `app/views/rbrun/skills/edit.html.erb`:

```erb
<%= render "rbrun/skills/form", skill: @skill, form: @form,
      skill_options:, tool_options: %>
```

Because `skill_options`/`tool_options` are private controller methods, expose them to views: add `helper_method :skill_options, :tool_options` near the top of `SkillsController` (right after the class declaration / `SKILLS_REPO`).

- [ ] **Step 8: Point "New skill" at the form**

In `app/views/rbrun/skills/index.html.erb`, replace the `with_actions` block's `form_with`/button that posts to `build_skill_path` with a link to the form:

```erb
  <% s.with_actions do %>
    <%= component("button", variant: :primary, size: :sm, href: rbrun.new_skill_path) do %>
      <%= lucide_icon("plus", class: "size-4") %> New skill
    <% end %>
  <% end %>
```

(The `build`/`build_skill` drawer route stays for now — it's just no longer the primary entry point. Removing the AI-assisted create-skill flow is out of scope for Plan 1.)

- [ ] **Step 9: Run the controller tests**

Run: `bin/rails test test/controllers/rbrun/skills_flow_test.rb`
Expected: PASS (new/create/edit/update/version/taken + the pre-existing index/reconcile tests).

- [ ] **Step 10: Run the full suite + lint**

Run: `bin/rails test && bin/rubocop -a`
Expected: all green; rubocop clean (autofix any style nits, re-run).

- [ ] **Step 11: Commit**

```bash
git add config/routes.rb app/controllers/rbrun/skills_controller.rb \
        app/views/rbrun/skills/new.html.erb app/views/rbrun/skills/edit.html.erb \
        app/views/rbrun/skills/_form.html.erb app/views/rbrun/skills/_version_picker.html.erb \
        app/views/rbrun/skills/index.html.erb test/controllers/rbrun/skills_flow_test.rb
git commit -m "feat(skills): the authoring form — new/create/edit/update + version picker

Vanilla resourceful skills form composed from Ui primitives; create packs a
v1, update merges the edited SKILL.md onto the base version's files and
promotes. Version dropdown reloads any version into the form.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (against the spec)

- **Spec coverage (Plan 1 slice):** `Rbrun::SkillForm` fields ⇄ `SKILL.md` incl. `preferred_*` lists + body (Task 2); vanilla `new`/`create`/`edit`/`update` — create→v1, update→`promote!` a new version, `?version=` load (Task 3); `sessions.kind` enum + index filter (Task 1). Deferred to Plan 2: scenarios = skill-bound workflows, `▶ Run`, `showcase_artifact_version_id`, `workflows.skill_id/prompt`, retiring `SkillScenario`.
- **Archive-is-truth:** no card/soft-hint column added; create/update assemble `SKILL.md` and `promote!`; edit parses the selected version's archive; update preserves non-`SKILL.md` files (test asserts `reference.md` survives).
- **Primitives only:** the form uses `field`/`textarea`/`select`/`multi_select`/`button`/`surface`/`form_section` via `component(...)` — no raw `<input>`/`<select>`/`<button>`; the version picker uses `select`+`button`.
- **Type consistency:** `SkillForm.new` accepts params/Hash; `form_params` permits the exact keys the form posts (`skill[...]`, lists as `preferred_skills: []`); `multi_select name: "skill[preferred_skills]"` (component appends `[]`) matches the permit; `promote!(digest:, archive:, source:)` used identically in create/update and the test helper.
- **No placeholders:** every step carries real code; `current_repo_for_test` / tenant strings are called out as "read the existing flow test and use its exact values" — the one spot that depends on the current test's fixtures.

## Handoff

After Plan 1 is green, write **Plan 2 — scenarios = skill-bound workflows + run** (add `workflows.skill_id`/`prompt`/`showcase_artifact_version_id`, `Skill has_many :workflows`, retire `SkillScenario`, nested `resources :workflows` form, wire `▶ Run` → `SkillScenarioRun` as `:skill_scenario`).
