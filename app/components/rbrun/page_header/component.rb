module Rbrun
  module PageHeader
    # A page card's header row: an optional back arrow, a title, and right-aligned actions. Ported from
    # ../insitix (Custom::PageHeader). h-16 is a DECLARED height (not padding-derived) so the page header
    # and any side-panel header land at the same height whatever their contents — with padding alone an
    # h1 (text-xl) and a tab strip (text-sm) would differ and the divider would step across the seam.
    # Nothing to draw is not an empty bar with a border under it (render? guard).
    class Component < Rbrun::ApplicationViewComponent
      def initialize(title: nil, back: nil)
        @title = title
        @back = back
      end

      attr_reader :title, :back

      def render? = title.present? || back.present? || content.present?
    end
  end
end
