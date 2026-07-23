require "stringio"

module Rbrun
  module Tools
    # Save a SINGLE workspace file as a versioned artifact — a first-class deliverable (a report, a
    # document) that outlives the turn. Ungated: producing a deliverable is leaf output, not a state
    # mutation. The bytes travel via the workspace file, never through the tool-call payload.
    class SaveArtifact < Rbrun::ApplicationTool
      description <<~TXT
        Save a single file from your workspace as a versioned artifact — a first-class deliverable such
        as a report or document. Write the file first, then call this with its workspace-relative `path`.
        Omit `artifact_id` to create a new artifact; pass it to add a new version to an existing one.
      TXT

      parameter :path, type: "string", required: true,
                description: %(workspace-relative path to the file to save, e.g. "report.md")
      parameter :name, type: "string", required: false,
                description: "human name for the artifact (defaults to the file's basename)"
      parameter :artifact_id, type: "integer", required: false,
                description: "existing artifact id to add a new version to; omit to create a new one"

      def execute(path:, name: nil, artifact_id: nil)
        message = session.open_turn_lead
        return error("no active turn to attribute this artifact to") unless message

        bytes   = session.sandbox.read(path)
        version = Rbrun::Artifact.append_version!(
          tenant: tenant, message: message, io: StringIO.new(bytes),
          filename: File.basename(path), name: name, artifact_id: artifact_id
        )
        { "data" => { "artifact_id" => version.artifact_id, "name" => version.artifact.name,
                      "version" => version.number, "content_type" => version.content_type,
                      "byte_size" => version.byte_size } }
      rescue ActiveRecord::RecordNotFound
        error("artifact ##{artifact_id} not found for this tenant")
      end
    end
  end
end
