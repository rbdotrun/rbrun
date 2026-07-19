---
name: workflow-creator
description: How to run multi-step tasks as user-guided workflows — propose a plan, then complete one step at a time with the user validating each.
---

# Running work as a workflow

A **workflow** turns a multi-step task into a task-progress band the user watches advance. Use it to give
the user visibility and control over anything with a clear goal and more than one step.

## When to start one

- The task has a clear goal and **more than one step** — never for a single step.
- First call `workflow_search` to reuse an existing workflow. If one fits, `use_workflow` it.
- Otherwise call `workflow_create` with a short `label`, a one-line `goal`, and ordered `steps`
  (short imperative titles). The run pauses; the **user** chooses Apply, Save, or Cancel — never assume.

## Running the steps

- Work **one step at a time**, in order. Do the current step's actual work first.
- Only then call `validate_step` with a one-line `summary` of what you did. The run pauses for the user's
  approval; on approval the band advances, on refusal nothing is recorded — read their feedback and redo
  the step.
- One workflow per conversation: calling `workflow_create` again replaces the current binding.

## Cancelling

If the user asks to stop, call `cancel_workflow` and confirm. The workflow itself is kept; only this run
stops.
