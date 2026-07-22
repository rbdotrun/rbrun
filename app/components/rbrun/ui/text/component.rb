module Rbrun
  module Ui
    module Text
      # Typography scale. One primitive, named variants — product-register sizes. Faithfully ported
      # from ../insitix (Primitives::Text).
      class Component < Rbrun::ApplicationViewComponent
        VARIANTS = {
          page_title: { tag: :h1,   class: "text-2xl font-bold tracking-tight text-slate-900" },
          title:      { tag: :h2,   class: "text-lg font-semibold text-slate-800" },
          subtitle:   { tag: :p,    class: "text-sm text-slate-500" },
          body:       { tag: :p,    class: "text-sm text-slate-700" },
          muted:      { tag: :p,    class: "text-xs text-slate-400" },
          label:      { tag: :span, class: "text-xs font-medium uppercase tracking-wide text-default-600" }
        }.freeze

        def initialize(variant: :body, as: nil, **attrs)
          @variant = variant
          @as = as
          @attrs = attrs
        end

        def call
          spec = VARIANTS.fetch(@variant)
          content_tag(@as || spec[:tag], content, class: class_names(spec[:class], @attrs.delete(:class)), **@attrs)
        end
      end
    end
  end
end
