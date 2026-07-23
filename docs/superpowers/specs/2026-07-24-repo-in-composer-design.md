# Repo selection in the composer — design

**Date:** 2026-07-24
**Status:** design (stacked on the `skill-editor` branch / PR #16)

## Purpose

Kill the **repo trap**: today a repo is chosen from the **sidebar switcher**, stored as a global
`current_repo` (a Rails-session cookie), and it silently scopes *everything* — the conversation index,
what a new chat runs against, everything. That global scope is exactly why a skill's example can only run
"bare" (no repo) — there's no per-run place to say "run this against that repo."

Move repo selection to **where the work starts: the composer.** A repo is a **per-chat** choice made when
you compose, not a global mode. This frees skills/scenarios from any repo binding (a scenario stays
repo-agnostic; the repo is an input to the *run*, chosen at compose time) and lets "select a repo → run"
work uniformly for conversations and, later, scenario runs.

## The decisions (converged)

1. **Single repo per chat** — one repo, not many. No multi-checkout. (`Worktree` stays one-repo.)
2. **`Worktree` is unchanged and kept (option A).** The repo binding stays on `Worktree`; a chat's repo
   **resolves to a worktree** (the same mechanism `current_repo → worktree_for(repo)` uses today).
   Sessions on the same worktree still **share one sandbox** — concurrent agents in the same box on the
   same branch is **accepted** (a shared mutable checkout; the model doesn't prevent collisions, by design).
3. **Two entry points, no find-or-create guessing:**
   - **Compose from the root home → a NEW worktree** (+ its first session), every time.
   - **Open an existing worktree → reuse it** (its repo/branch/box); a new session joins it.
4. **Repo is picked in the composer** as a **badge/chip**: an empty "Select a repository" pill →
   opens the picker → becomes `owner/name ✕`, where **✕ clears it** (→ no repo / bare).
5. **Reuse the existing switcher dialog as-is** — only its *selection target* changes: instead of
   `POST /repos/switch` setting the global cookie, a pick **populates this composer's repo** (client-side,
   into the badge + a hidden field). Same searchable `/repos` Turbo-frame modal, same GitHub search.
6. **Locked after start.** The repo is editable **only while composing the first turn**. Once the chat has
   taken its first turn, the repo is **frozen** — the badge shows it read-only, no ✕.
7. **The sidebar switcher trigger is removed.** Repo is no longer a global sidebar mode.

## What changes (touch points)

### The composer gains a repo badge
- A new `composer/repo_badge` (a `custom(...)` folder component): renders either the empty
  "Select a repository" pill (opens the picker into `#modal`) or the selected `owner/name ✕` chip.
- It writes the choice into a **hidden field** in the compose form (`repo` + `base`) so submit carries it.
- **State:** editable when the chat has **no turns yet**; read-only (no ✕, no picker) once it does. The
  badge asks the session, not a flag: `session.nil? || session.messages.none?` ⇒ editable.

### The picker dialog is retargeted (client-side)
- `app/views/rbrun/repositories/_results.html.erb` rows currently pick → `POST /repos/switch`. They instead
  emit a **client-side pick** consumed by a small `repo-picker` Stimulus controller: it sets the badge
  label + the hidden `repo`/`base` fields on the owning compose form and closes the modal. **No global
  cookie is written.** The dialog shell + search + lazy results frame are unchanged.
- `RepositoriesController#switch` and the `session[:rbrun_repo]` cookie are **removed** (nothing writes
  the global scope anymore). `#index` (the searchable frame) stays exactly as-is.

### Root home = compose a new chat
- The root page (`sessions#index`) gains a **composer** (message textarea + the repo badge). Submitting:
  1. creates a **new `Worktree`** for the badge's `repo`/`base` (bare when no repo is set),
  2. creates a `Session` under it,
  3. runs the first turn (enqueues `AgentTurnJob`), and redirects to the chat.
- `SessionsController#create` takes `repo`/`base` (+ the first `message`) from the composer instead of
  reading `current_repo`. **New worktree every time** (per decision 3) — not find-or-create.

### The in-chat composer shows the locked repo
- `messages/_form` (the existing composer) renders the repo badge in its **locked** state (the chat has
  started), so you always see what repo the chat is bound to, read-only.

### The index becomes a worktree list, grouped by repo
- The root/index no longer filters sessions by a global `current_repo`. It lists the tenant's
  **`Worktree`s grouped by their `repo`** — repo is the group header (`owner/name`), each worktree is a
  row under it (its branch + a peek at its sessions). Opening a worktree shows **its** `:user` sessions.
- Concretely: the root page renders the **compose** form (new worktree) **above** the grouped worktree
  list (resume existing). A worktree row → the worktree's sessions (a `worktrees#show`, or the sessions
  list filtered to that `worktree_id`). Bare worktrees (no repo) group under an "Unassigned / scratch"
  header.
- `current_repo` / `current_repo_base` / the `session[:rbrun_repo]` cookie are removed — grouping comes
  from the worktrees' own `repo` column, not a global scope.

## Data model

**No schema change.** `Session → Worktree → repo` is untouched; `Worktree` keeps its `repo`/`base`. The
repo is resolved to a worktree at chat creation from the composer's fields, exactly as `current_repo` was.
"Locked after start" needs no column — it's derived from `session.messages.none?`.

## Flows

```
ROOT COMPOSE (new)                         OPEN EXISTING (reuse)
─────────────────                          ─────────────────────
root page composer                         root list: worktrees grouped by repo
  badge: pick repo (or none)                 owner/name
  type first message                           └─ worktree (branch) → its sessions
  submit                                   open one → a session in that worktree
    → new Worktree(repo,base)                → repo is locked (shown read-only)
    → new Session                            → compose more turns in the SAME box
    → first turn (AgentTurnJob)               (a new session can join the same worktree)
    → redirect to chat (repo now locked)
```

## Non-goals (explicitly later / accepted)

- **Multi-repo per chat** — single repo only, now.
- **Concurrency safety** for multiple agents in one shared sandbox/branch — **accepted as-is** (shared
  mutable checkout). Not solving collisions here.
- **Scenario runs consuming the composer repo** — `SkillScenarioRun` stays **bare** for now; once the
  composer carries a repo it can inherit the selection, but wiring that is a follow-up (the point of this
  branch is to remove the global-scope trap so that becomes possible).
- **A `Repo` table** — a repo remains a GitHub `owner/name` string; no entity.

## Invariants respected

- `Worktree` unchanged; repo binding + shared sandbox preserved (option A).
- No global mutable scope: repo is a per-chat input, resolved to a worktree, then immutable.
- Primitives only: the badge/chip composes `Ui::*` via `component(...)`; the dialog is reused untouched.
- No new schema; DB stays the source of truth.

## Testing

- **Composer badge:** editable with no turns (renders picker trigger + ✕); read-only once the session has
  a message (no ✕, no trigger).
- **Retargeted picker:** a pick sets the compose form's hidden `repo`/`base` and closes the modal; asserts
  **no** `session[:rbrun_repo]` cookie is written and `/repos/switch` is gone.
- **Root create:** `POST` with `repo` + first `message` creates a **new** `Worktree(repo)` + `Session`,
  enqueues the first turn, redirects to the chat; a second root compose on the same repo makes a **second**
  worktree (new-every-time, not find-or-create).
- **Bare create:** `POST` with no repo creates a bare worktree + session (the release-notes/create-skill
  path still works).
- **Lock:** the in-chat composer renders the repo read-only once the chat has started.
- **System test:** from root, open the picker, choose a repo (badge fills), send a first message → lands
  in a chat bound to that repo, badge locked.

## Plan slices

1. **Repo badge + retargeted picker** (client-side selection into a compose form; remove `/repos/switch`
   + the `session[:rbrun_repo]` cookie + `current_repo`/`_base` + the sidebar trigger).
2. **Root composer + new-worktree create** (compose first turn from root; `create` takes `repo`/`base` +
   the first `message`; **new worktree every time**).
3. **Grouped worktree index** (root lists `Worktree`s grouped by `repo`; open a worktree → its sessions —
   `worktrees#show` filtered to `worktree_id`).
4. **Lock-after-start** in the in-chat composer + the badge's read-only state.
