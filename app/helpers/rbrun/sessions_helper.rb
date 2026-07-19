require "redcarpet"
require "json"

module Rbrun
  # Conversation view helpers: markdown for assistant prose, tool_body for tool args/results, the
  # approval action form, and the tools-validation component resolver.
  module SessionsHelper
    MARKDOWN = Redcarpet::Markdown.new(
      Redcarpet::Render::HTML.new(escape_html: true, hard_wrap: true),
      autolink: true, fenced_code_blocks: true, tables: true, strikethrough: true
    )

    # Assistant prose → safe HTML (raw HTML in the source is escaped, not rendered).
    def markdown(text)
      return "".html_safe if text.nil? || text.to_s.empty?

      MARKDOWN.render(text.to_s).html_safe
    end

    # A tool's args/result rendered as a one-block string: pretty JSON for structured data, the raw
    # string otherwise.
    def tool_body(data)
      parsed = data.is_a?(String) ? (JSON.parse(data) rescue data) : data # rubocop:disable Style/RescueModifier
      parsed.is_a?(String) ? parsed : JSON.pretty_generate(parsed)
    end

    # The shared gate form (one PATCH, two submits keyed by decision).
    def approval_actions(tool_use_id)
      render "rbrun/sessions/approval_actions", tool_use_id: tool_use_id
    end

    # The validation card component for a tool. rbrun ships one fallback (Default); hosts add their
    # own per-tool cards by defining Rbrun::Sessions::ToolsValidation::<Name>::Component.
    def tools_validation_component(_name)
      Rbrun::Sessions::ToolsValidation::Default::Component
    end
  end
end
