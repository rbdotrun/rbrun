---
name: preview-deploy
description: Deploy this worktree's app to a public URL with Kamal — provision a server, point DNS, prepare the Dockerfile/deploy config, deploy, and hand back the live link. Use when the user asks to deploy, publish, or share a live preview.
---

# Deploying a worktree to a public URL

Take the code in this worktree from the sandbox to a **running, publicly reachable deployment**. Each step
below is a tool — the agent declares the intent; the engine handles the infra (it builds on our host from
the pushed branch, so the sandbox needs no Docker).

## When to use

The user asks to "deploy", "publish", "ship", or "share a live preview / real URL" of this worktree.

## The lifecycle (all tools are idempotent)

1. **`provision_server`** — find-or-create this worktree's server, record its IP.
2. **`create_deploy_dns`** — point the deploy host at that IP (A record).
3. **`prepare_deploy`** — write `config/deploy.yml` + a `Dockerfile`. **Adapt the Dockerfile to the app's
   stack** (see `examples/`), then **commit + push** — the build host builds from the branch.
4. **`deploy`** — build (Kamal local builder, on our host) and ship. **Gated: the user approves it.** It
   runs off-turn; poll **`deploy_status`** for the live URL and status.
5. **`save_deploy_tag`** — record a version label so we track what's deployed.
6. **`deploy_logs`** — the build/deploy output, or live container logs once it's up.
7. **`teardown_deploy`** — when finished, destroy the server + DNS. Never leave infra running.

## Notes

- One worktree = one deploy target. The tools always act on *this* worktree — no target name to pass.
- The Dockerfile is app-specific — start from `examples/Dockerfile.rails` or `examples/Dockerfile.node`
  and adjust (build steps, port, start command). `config/deploy.yml` is scaffolded for you (local builder,
  the server IP + registry come from the environment at build time — no secrets in the file).
- Hand the user the **live URL** from `deploy_status` once the deploy reports `deployed`.
