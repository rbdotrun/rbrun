module Rbrun
  module Ui
    module SingleUpload
      # Self-contained single-attachment control (logo, banner, avatar): one dashed box holding a
      # thumbnail-or-fallback, the label, the current filename, and an inline clear button. The whole box
      # picks a file; drop works too. A hidden remove_* input (0/1) drives purge-on-save. `media` is an
      # ActiveStorage::Attached::One (optional — without it the placeholder shows). Faithfully ported.
      class Component < Rbrun::ApplicationViewComponent
        def initialize(label:, name:, media: nil, accept: "image/*", remove_name: nil)
          @label = label
          @name = name
          @media = media
          @accept = accept
          @remove_name = remove_name
        end

        private

          attr_reader :label, :name, :media, :accept, :remove_name

          def attached? = media&.attached?
          def image?    = attached? && media.content_type.to_s.start_with?("image/")

          def preview_src = image? ? helpers.rails_blob_path(media, disposition: "inline") : nil
          def filename    = attached? ? media.filename.to_s : default_subtitle
          def default_subtitle = "Click to add or drag and drop"
          def hint = accept.to_s.include?("image") ? "PNG, JPG, GIF or WebP" : nil
      end
    end
  end
end
