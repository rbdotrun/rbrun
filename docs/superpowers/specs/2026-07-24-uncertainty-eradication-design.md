# Uncertainty eradication — fallbacks are a design smell

**Date:** 2026-07-24
**Status:** design + standing rule (drives the `fallback-audit` branch)

## The rule

> **A fallback (`||` or a ternary) means the outer context was not reconsidered.**

When a value can be absent, `x || <guess>` dodges the real question — *what should the system DO when
this is missing?* — and answers a different, easier one: *what value looks plausible here?* The guess is
wrong-but-shaped-right, so it doesn't fail at the point of ignorance; it fails somewhere far away, with
a symptom that points at the wrong code.

The honest answers are always one of three:

1. **Fail loud** — the operation cannot be correct without it. `raise`, at the point of ignorance.
2. **Gate the feature** — the capability is unavailable; disable/skip it rather than fake it.
3. **Handle the absence explicitly** — a real, designed "none" path (an empty state, a `nil` return the
   caller is written to expect).

Guessing a **literal** — a branch name, a domain, a region, an image, a model, a policy — is the sharp
edge of the smell. It manufactures a fact the system does not have.

## Calibration (the two that started this)

- `Rbrun.config.preview_domain.presence || "preview.local"` → **fail loud.** A deploy host built on a
  guessed domain is non-routable; the failure surfaces at deploy time, nowhere near the guess.
  `preview_domain` now defaults to `nil` (a distributed engine has no universal domain) and
  `provision_server` raises. The feature is gated on real config. ✅ landed
- `hash["default_branch"] || "main"` → **resolve authoritatively.** A repo's default may be
  `master`/`develop`; a wrong base spins a worktree off a branch that doesn't exist. The value now comes
  from the API (`GithubRepos#default_branch`), and the composer's pick carries it. ✅ landed

## What is NOT a smell

Not every `||` is a flaw. These are legitimate and must not be churned:

- **Collection/count coalescing** — `x || []`, `|| {}`, `|| 0` purely so iteration or summing is safe.
- **Memoization** — `@x ||= …`.
- **Presentational defaults** — a component's `variant:`/`size:`/`preset:` API, a computed grid template,
  a display placeholder for genuinely empty content ("New conversation").
- **Computed defaults derived from real inputs** — not a guessed constant.
- **Find-or-create** — `find_by(…) || create!(…)` where creating is the intended path.

The test: *does the fallback invent a fact the system doesn't have?* If yes → smell. If it merely makes
an empty thing safe to iterate, or picks a presentation knob → fine.

## Scope

~190 sites: ~114 `||` and ~65 ternaries across `app/` + `lib/` + `gems/`, plus ~10 in `app/javascript/`.
Audited area-by-area; each site gets a verdict (JUSTIFIED with a reason, or FLAW with a concrete fix).

## Process

1. **Audit** — enumerate every site, read the *outer context* (the method and its callers), verdict each.
2. **Fix** — for each FLAW apply fail-loud / gate / explicit-absence, and add or adjust the test that
   proves the new behaviour (a raise is a behaviour; it needs a test).
3. **Gate the config** — where a fallback masked missing configuration, the config default becomes `nil`
   and the dependent feature is blocked, so absence is visible instead of simulated.

## Guardrail (so this doesn't regress)

The pre-commit hook (`.githooks/pre-commit`, `git config core.hooksPath .githooks`) runs lint + tests and
guards the `Gemfile.lock` platforms. **Never `--no-verify`** — a red gate means the code is broken; the
bypass converts a caught failure into a shipped one.

## Non-goals

- Mechanically deleting every `||`. The goal is *eradicating invented facts*, not a syntax purge.
- Churning presentational defaults or collection coalescing.
