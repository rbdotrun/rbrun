module Rbrun
  module Ui
    module MultiSelect
      # Checkbox group posting `name[]` (a hidden "" makes clearing submittable). A flat list renders as
      # a 2-col grid; a parent-grouped catalog ([[group, [[label, value]…]]…]) renders sub-headings with a
      # search that hides groups with no match (option-filter). Faithfully ported from ../insitix.
      class Component < Rbrun::ApplicationViewComponent
        SEARCH_AT = 8

        def initialize(label:, name:, options:, selected: [], grouped: false)
          @label = label
          @name = name
          @options = options
          @selected = Array(selected).map(&:to_s)
          @grouped = grouped
        end

        attr_reader :label, :name, :options, :grouped

        def groups = @grouped ? options : [ [ nil, options ] ]
        def total = groups.sum { |_g, items| items.size }
        def searchable? = total >= SEARCH_AT
        def selected?(value) = @selected.include?(value.to_s)
      end
    end
  end
end
