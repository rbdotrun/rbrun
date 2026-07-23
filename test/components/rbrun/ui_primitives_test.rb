require "test_helper"

module Rbrun
  # Smoke test: every ported primitive instantiates and renders without error. Catches missing
  # helpers (image_tag/options_for_select/check_box_tag in `call`), broken constant refs, and template
  # errors — across the whole primitives set in one place. Runs under the engine controller so the
  # registered helper chain (e.g. markdown) is present.
  class UiPrimitivesTest < ViewComponent::TestCase
    test "every primitive renders" do
      with_controller_class(Rbrun::ApplicationController) do
        assert_match "B", render_inline(Ui::Avatar::Component.new(name: "Ben")).to_html
        assert_match "form-input", render_inline(Ui::Field::Component.new(label: "Email", name: "email")).to_html
        assert_match "form-input", render_inline(Ui::Input::Component.new(name: "q")).to_html
        assert_match "<option", render_inline(Ui::Select::Component.new(label: "C", name: "c", options: [ [ "A", "a" ] ])).to_html
        assert_match "<textarea", render_inline(Ui::Textarea::Component.new(label: "B", name: "b")).to_html
        assert_match "checkbox", render_inline(Ui::Switch::Component.new(name: "on")).to_html
        assert_match "checkbox", render_inline(Ui::Checkbox::Component.new(name: "a")).to_html
        assert_match "radio", render_inline(Ui::Radio::Component.new(name: "p", value: "1")).to_html
        text = Ui::Text::Component.new(variant: :title)
        text.with_content("Hello")
        assert_match "Hello", render_inline(text).to_html
        assert_match "border-t", render_inline(Ui::Section::Component.new(title: "Bits")).to_html
        assert_match "grid", render_inline(Ui::FormSection::Component.new(title: "Form")).to_html
        assert_match "nav", render_inline(Ui::Pagination::Component.new(page: 2, total_pages: 5, href: ->(n) { "/#{n}" })).to_html
        assert_match "nav", render_inline(Ui::Tabs::Component.new(tabs: [ { label: "A", href: "/", key: "a", active: true } ])).to_html
        assert_match "grid-template-columns", render_inline(Ui::Table::Component.new(columns: [ "Name" ])).to_html
        assert_match "Card", render_inline(Ui::VisualCard::Component.new(title: "Card")).to_html
        assert_match "Item", render_inline(Ui::ListCard::Component.new(title: "Item", icon: "star")).to_html
        assert_match %(role="menuitem"), render_inline(Ui::ListItem::Component.new(title: "o/n", subtitle: "o", avatar: "ON", href: "/x")).to_html
        assert_match "animate-pulse", render_inline(Ui::Skeleton::Component.new(variant: :list_item, rows: 2)).to_html
        surface = Ui::Surface::Component.new(title: "S", preset: :dialog)
        surface.with_body { "B" }
        assert_match "rounded-xl", render_inline(surface).to_html
        assert_match "longtext", render_inline(Ui::Longtext::Component.new.with_content("# Hi")).to_html

        # Batch 2: drawer family + controller-driven primitives + uploads + native select/date.
        assert_match %(data-controller="overlay"), render_inline(Ui::Drawer::Component.new).to_html
        dp = Ui::DrawerPanel::Component.new(title: "T")
        dp.with_actions { "SAVE" }
        dp_html = render_inline(dp).to_html
        assert_match %(id="drawer_body"), dp_html
        assert_match %(id="drawer_actions"), dp_html
        assert_match "SAVE", dp_html
        assert_match %(data-command-target="input"), render_inline(Ui::SearchInput::Component.new).to_html
        assert_match "option-filter", render_inline(Ui::MultiSelect::Component.new(label: "L", name: "x[]", options: [ [ "G", [ [ "a", "a" ] ] ] ], grouped: true)).to_html
        assert_match "bulk-select", render_inline(Ui::BulkBar::Component.new(singular: "row", plural: "rows")).to_html
        assert_match "dropzone", render_inline(Ui::Dropzone::Component.new(name: "f")).to_html
        assert_match "single-upload", render_inline(Ui::SingleUpload::Component.new(label: "Logo", name: "logo")).to_html
        assert_match "<select", render_inline(Ui::InputSelect::Component.new(name: "c", options: [ [ "A", "a" ] ])).to_html
        assert_match %(type="date"), render_inline(Ui::InputDate::Component.new(label: "D", name: "d")).to_html
        assert_match "rich-text-area", render_inline(Ui::RichTextArea::Component.new(name: "body")).to_html

        # The dialog family renders too (shells + button via component()).
        assert_match %(data-controller="overlay"), render_inline(Ui::Dialog::Component.new).to_html
        assert_match "confirm-dialog", render_inline(Ui::ConfirmDialog::Component.new).to_html
        assert_match "data-confirm-accept", render_inline(Ui::ConfirmDialog::Component.new).to_html
      end
    end
  end
end
