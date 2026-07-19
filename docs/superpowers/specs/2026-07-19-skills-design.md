# Skills — Design

> Feature spec. Extends the rbrun engine design (`2026-07-19-rbrun-design.md`). One spec → one
> just-in-time plan → branch → TDD → dogfood → PR.

**Goal:** Give rbrun first-class **skills** — the capability folders the agent reads off its
workspace — authored from files or inline config, stored and versioned in rbrun's own database, and
staged into the sandbox per turn.

## The invariant (load-bearing)

**The agent stages skills from the database — the current `SkillVersion`'s archive — never from the
host's files or config at turn time.** File and inline config are *seed sources only*: they populate
the DB. Once seeded, the DB is the single source of truth the runtime materializes and stages. This
is what makes skills work per-tenant, survive editing/versioning, and keeps the runtime oblivious to
where a skill was authored.

```
file / inline  ──seed──▶  rbrun_skills (+ versions)  ──materialize──▶  <sandbox>/.claude/skills/
  (authoring)             DB: canonical, versioned      (per turn, the runtime writes the
                          store — surface, edit, diff     current version's folder the SDK reads)
```

A **skill is a folder** (`SKILL.md` + optional resource files), never just a string.

---

## 1. Config API — seed sources (host → config)

Mirrors the `c.user` idiom: a directory convention plus a repeatable inline form. Both feed the
seeder; neither is read at turn time.

```ruby
Rbrun.configure do |c|
  # Convention: a host directory of skill folders — <path>/<slug>/SKILL.md (+ resource files).
  c.skills_path = Rails.root.join("app/skills")

  # Inline, repeatable. Shorthand (slug + SKILL.md body):
  c.skill "pdf-report", <<~MD
    ---
    name: PDF report
    ---
    …instructions…
  MD
  # Multi-file:
  c.skill slug: "invoice", name: "Invoice",
          files: { "SKILL.md" => "…", "template.tex" => "…" }
end
```

`c.skills_path` is globbed for `*/SKILL.md` folders (each dir name = slug). `c.skill` appends inline
skills. Both are collected on `Rbrun::Config` and consumed only by the seeder.

## 2. Storage — `Rbrun::Skill` + content-addressed `Rbrun::SkillVersion`

Tenant-scoped (always-on tenancy). A `Skill` is identity; a `SkillVersion` is immutable content.

```
rbrun_skills            (tenant, slug, name, current_version_id, divergence_digest, created_at, updated_at)
                        index: [tenant, slug] UNIQUE
rbrun_skill_versions    (skill_id, digest, archive, source, created_at)
                        index: [skill_id, digest] UNIQUE ; source enum: file | inline | ui
```

- `archive` — the whole skill folder as one gzipped tar (`SKILL.md` + files), a single binary blob.
- `digest` — a **content** hash (SHA256 over sorted `(relpath, bytes)` entries), **not** the gz bytes
  (tar/gzip stamp mtime, so archive bytes aren't a pure function of content). Two folders with the
  same files ⇒ same digest.
- `current_version_id` — the version the runtime stages.
- `divergence_digest` — set when an authored source differs from `current` (see §4); nil when clean.

## 3. Archive — folder ⇄ blob (`Rbrun::SkillArchive`)

Pure Ruby engine service (`Gem::Package::TarWriter` + `zlib`), one round-trip:
- `pack(dir) -> blob` / `pack_files(hash) -> blob` — gzipped tar of a folder or an inline `{path=>bytes}`.
- `unpack(blob, into:) -> dir` — recreate the folder (used at stage time).
- `digest(dir | files) -> hex` — content hash for version identity + diff.
Paths are stored relative to the skill root (`SKILL.md`, never `pdf-report/SKILL.md`); the destination
folder is named by slug at unpack time.

## 4. Seeder — compare, never clobber (`Rbrun::SkillSeeder`)

For each authored skill (file or inline), pack → `digest` → compare to the skill's `current`:

| Case | Action |
|---|---|
| no `Skill` for the slug | create `Skill` + first `SkillVersion` (source), set `current`. (Authoring, not conflict.) |
| `digest == current.digest` | no-op; clear any `divergence_digest`. |
| `digest != current.digest` | **divergence**: leave `current` untouched, set `divergence_digest`, **warn**. |
| pack/parse fails (bad folder, missing/broken `SKILL.md` frontmatter) | **issue**: warn, create nothing. |

The seeder **never auto-applies** a change. Runs at boot (engine `after_initialize`, warn-only) and
on demand via `rbrun:skills:seed`. Warnings go to the boot log **and** the persisted
`divergence_digest` so the UI can surface them.

**Resolution — the warn → Cancel / Reload contract** (same verbs everywhere):
- **Reload** — apply the authored source: append a `SkillVersion` (its digest), move `current`,
  clear `divergence_digest`, re-stage. *Make live match source, as a new version.*
- **Cancel** — keep `current`; clear `divergence_digest` (dismiss). The source and DB stay diverged.

## 5. Staging — DB → sandbox (per turn)

`AgentTurn#call_client` materializes the acting tenant's skills before the run:
`Rbrun::Skill.for_tenant(t)` → for each, `SkillArchive.unpack(current.archive, into: "<tmp>/<slug>")`
→ `runtime.run(skills: tmp_dir, …)`. The runtime is unchanged (`stage_skills(dir)` uploads the tree
into `<workspace>/.claude/skills/`). No skill exists in the sandbox that isn't a current DB version.

## 6. `reload_skills` tool

`Rbrun::Tools::ReloadSkills < ApplicationTool` (runs back in Ruby, no approval): re-materialize the
tenant's current `SkillVersion`s from the DB and re-stage them into `.claude/skills/`. **Effective
next turn** — the SDK discovers skills at run init (client.ts reads `SKILLS_DIR` once at process
start), so a mid-turn reload freshens the folder for the *next* turn, not the running query. Its
contract is stated as "freshen skills for the next turn". It is a **Reload from the DB** — same verb
as the UI button.

## 7. Diff-surfacing UI — the Skills panel

Entry point: a **"Skills"** link in the **footer user dropdown** (bottom of the sidebar rail, above
"Sign out") — the manage-my-workspace menu, not per-conversation nav.

`Rbrun::SkillsController#index` → a panel listing the tenant's skills: name, slug, current version
(short digest), `source`, updated-at. For any skill with a `divergence_digest` **or** a seed issue, a
banner shows the problem + the **diff** (authored source vs `current`), with **[Cancel]** and
**[Reload]** actions (`#reconcile`, `decision: cancel|reload`). Reload appends a version + moves
`current`; Cancel clears the flag.

## 8. Out of scope (next pass)

- **In-UI content editing** (a skill editor authoring `source: :ui` versions).
- **Edit → git commit** — how an accepted/edited DB version flows back to files/git as a commit.
Both build on the versioned model here.

## 9. Dogfood gate — `dogfood/skills.rake`

Seed one skill from a folder + one inline; run a **real turn** where the agent uses the skill (real
Claude + real sandbox); then edit the file to diverge and re-seed → the divergence is surfaced (not
applied); Reload → a new current version stages. ✓/✗. Never variabilized.

## 10. Inherited invariants

- Always-on tenancy — every skill/version carries the tenant slug; the panel + staging scope to it.
- No registry / no self-registration; the tool is host-registerable like any `ApplicationTool`.
- Skills are an **engine** concern (models, archive service, seeder, UI, tool) — the pure sub-gems
  are untouched; the runtime only gains nothing (it already takes `skills:` as a directory).
