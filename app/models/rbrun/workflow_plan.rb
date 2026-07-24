module Rbrun
  # The `workflow_create` tool's frozen ARGUMENTS — the agent's proposal, exactly as the user saw it on
  # the gate card, before any of it becomes a record.
  #
  # Tool arguments arrive from the model as JSON and are stored verbatim on the gate row
  # (session_messages.payload["input"]), because arbitrary tool args cannot be column-modelled. This
  # class is the ONE place that knows their shape: parse once here, then hand the rest of the app real
  # values. Re-deriving them from a raw hash at every read site is what bred the coercion (`.to_s`,
  # `Array(…)`) and the `|| "Untitled workflow"` guess — a rename in the tool silently read nil, and the
  # fallback quietly invented an identity for a malformed payload.
  #
  # Workflows themselves are fully modelled (Workflow + WorkflowStep rows). This is strictly the
  # JSON → models boundary, and it exists only because the source really is a JSON tool call.
  class WorkflowPlan
    def self.from(input) = new(input.is_a?(Hash) ? input : {})

    def initialize(raw)
      @raw = raw
    end

    def label       = @raw["label"].to_s.strip
    def goal        = @raw["goal"]
    def description = @raw["description"]
    def steps       = Array(@raw["steps"]).map { |s| s.to_s.strip }.reject(&:empty?)

    # `label` and `steps` are both `required: true` on the tool schema, so a blank one means the frozen
    # call is malformed — a corrupt gate, not a nameable workflow.
    def usable? = label.present? && steps.any?
  end
end
