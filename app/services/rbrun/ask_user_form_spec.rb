module Rbrun
  # A read model over the frozen ask_user form_spec (string-keyed). ONE place answers "what were the
  # questions / options / labels", so the card, the validator and the resume nudge never disagree. The
  # agent declared the options; the submission is a TRUST BOUNDARY validated against them here.
  class AskUserFormSpec
    def initialize(spec) = @spec = spec || {}

    def title     = @spec["title"].to_s
    def steps     = Array(@spec["steps"])
    def questions = steps.flat_map { |s| Array(s["questions"]) }
    def keys      = questions.map { |q| q["key"].to_s }

    def question(key)      = questions.find { |q| q["key"].to_s == key.to_s }
    def multiple?(key)     = question(key)&.dig("input") == "checkbox"
    def option_values(key) = Array(question(key)&.dig("options")).map { |o| o["value"].to_s }

    # value → label, for rendering answers (and the recap) as words, not machine values.
    def label_for(key, value)
      Array(question(key)&.dig("options")).find { |o| o["value"].to_s == value.to_s }&.dig("label") || value
    end

    # [] when clean, else messages. The trust boundary: every required question answered, every value ∈
    # the declared options, and no unknown keys — so the agent never resumes on a value it never offered.
    def errors(answers)
      answers = answers || {}
      msgs = []
      questions.each do |q|
        key = q["key"].to_s
        picked = Array(answers[key]).reject(&:blank?)
        msgs << "#{q['label']} is required" if q["required"] && picked.empty?
        msgs << "#{q['label']}: invalid choice" if (picked - option_values(key)).any?
      end
      unknown = answers.keys.map(&:to_s) - keys
      msgs << "unknown fields: #{unknown.join(', ')}" if unknown.any?
      msgs
    end

    # The app-voice recap fed to the agent as the resume nudge — LABEL-resolved, so it continues on
    # meaning ("Region → Île-de-France"), not machine values ("region=idf").
    def recap(answers)
      lines = questions.filter_map do |q|
        key = q["key"].to_s
        picked = Array((answers || {})[key]).reject(&:blank?)
        next if picked.empty?

        "- #{q['label']} → #{picked.map { |v| label_for(key, v) }.join(', ')}"
      end
      "The user answered the form:\n#{lines.join("\n")}\nContinue with these choices."
    end
  end
end
