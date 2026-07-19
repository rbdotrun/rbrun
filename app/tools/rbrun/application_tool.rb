require "ruby_llm"

module Rbrun
  # Base for every tool. A tool acts AS a tenant (the session's slug) and, for agentic tools, inside
  # a Session. It IS the operation (no service layer): it holds its schema + logic. RubyLLM is used
  # ONLY here (the tool DSL + ruby_llm-schema); it never reaches the sub-gems.
  class ApplicationTool < RubyLLM::Tool
    # RubyLLM::Parameter is name/type/description/required — no ITEM type for arrays. `items` (a
    # lambda, resolved at manifest time so a DB-backed enum doesn't query at class load) rides on the
    # Parameter itself, string-keyed (the manifest is JSON the client reads verbatim).
    class Parameter < RubyLLM::Parameter
      def initialize(name, items: nil, **options)
        @items = items
        super(name, **options)
      end

      def items = @items&.call
    end

    def self.parameter(name, **options)
      parameters[name] = Parameter.new(name, **options)
    end

    # Metadata-only by default (find/manifest read .name/.description). An execution given no session
    # fails loudly on @session, never silently.
    def initialize(tenant: nil, session: nil)
      @tenant = tenant
      @session = session
      super()
    end

    # Build a tool for a turn: the Session is Tenanted, so it is BOTH the tenant slug and the session.
    def self.in_session(session) = new(tenant: session.tenant, session: session)

    IDENTITY_TOOL = "identity"

    # Resolve a tool NAME to its class (the gate needs this to run a frozen call). Only the roster.
    def self.find(name) = Rbrun.tools.find { |klass| klass.new.name == name }

    # Does this operation need the owner's go-ahead? DECLARED on the tool — a property of the
    # operation, not a per-caller setting.
    def self.needs_approval! = @needs_approval = true
    def self.needs_approval?  = @needs_approval == true

    # A gated tool whose approval is a CUSTOM inline card with its OWN submission (a structured form —
    # ask_user's stepper), not the yes/no ApprovalsController. DECLARED here, exactly like
    # needs_approval! (a custom approval IS a gate, so this implies it), and named by the submit route
    # helper the card posts to. Enforced at boot (validate_tool_approvals!): a declaration without its
    # Rbrun::Sessions::ToolsValidation::<Name>::Component card OR its submit route fails the boot.
    def self.custom_approval!(submit:)
      @needs_approval = true
      @custom_approval = true
      @approval_submit_route = submit
      # A gate tool has NO computed result — its operation is the user's SUBMISSION (run by the submit
      # controller). So the declaration supplies the degrade execute a stray hand-call would need; no
      # gate tool re-declares a no-op.
      define_method(:execute) { |**| { "data" => { "gated" => submit.to_s } } }
    end
    def self.custom_approval?      = @custom_approval == true
    def self.approval_submit_route = @approval_submit_route

    # The roster serialized to the SDK-client shape (name + description + params + gating).
    def self.manifest = Rbrun.tools.map { |klass| manifest_entry(klass) }

    def self.manifest_entry(klass)
      { "name" => klass.new.name,
        "description" => klass.description.to_s,
        "needs_approval" => klass.needs_approval?,
        "parameters" => klass.parameters.values.map do |p|
          entry = { "name" => p.name.to_s, "type" => p.type.to_s,
                    "description" => p.description.to_s, "required" => !!p.required }
          entry["items"] = p.items if p.respond_to?(:items) && p.items
          entry
        end }
    end

    # RubyLLM derives the name from the FULL class name (Rbrun::Tools::Identity → "rbrun--tools--
    # identity"). Demodulize so a namespaced engine tool gets a clean name ("identity").
    def name = self.class.name.to_s.demodulize.underscore.delete_suffix("_tool")

    private

    attr_reader :session

    # Acting identity — the session's tenant slug. One source; nil for a bare metadata instance.
    def tenant = @tenant

    # The ruby_llm recoverable-error convention: return, don't raise. Always string-keyed.
    def error(message) = { "error" => message }
  end
end
