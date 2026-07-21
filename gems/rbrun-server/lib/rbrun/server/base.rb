# frozen_string_literal: true

module Rbrun
  module Server
    # The interface every server adapter MUST implement — the contract the engine relies on, independent of
    # which provider is configured. Adapters inherit from Base and override each method; a provider that
    # forgets one fails loud with NotImplementedError instead of a confusing NoMethodError. Pure
    # documentation + enforcement: no behaviour, no state, no dependencies.
    #
    # SSH keys flow PER CALL, not from config — the engine generates + stores a keypair per deployment
    # ("infra we own") and hands the adapter the public key to upload and the private key to deploy with.
    # Every mutating method MUST be idempotent by server name (invariant #11).
    class Base
      # Find-or-create the server by name (uploading + attaching ssh_public_key); block until it has a
      # public IP / reaches running. @return [Node]
      def create_server(name:, type:, region:, image:, ssh_public_key:, user_data: nil, labels: {})
        raise NotImplementedError, "#{self.class}#create_server"
      end

      # The server with this name, or nil. @return [Node, nil]
      def find_server(name:)
        raise NotImplementedError, "#{self.class}#find_server"
      end

      # Every server the account owns, optionally narrowed by label. @return [Array<Node>]
      def list_servers(label: nil)
        raise NotImplementedError, "#{self.class}#list_servers"
      end

      # Destroy the server by name. True if one was deleted, false if there was nothing to delete.
      # @return [Boolean]
      def destroy_server(name:)
        raise NotImplementedError, "#{self.class}#destroy_server"
      end

      # Deploy the app in work_dir onto the server via Kamal (local builder), authenticating over SSH with
      # ssh_private_key. @return [DeployResult]
      def deploy(work_dir:, host:, server_ip:, ssh_private_key:, env: {})
        raise NotImplementedError, "#{self.class}#deploy"
      end

      # The deployed app's container logs from the server (parity with repo_services logs). @return [String]
      def app_logs(work_dir:, server_ip:, ssh_private_key:, tail: 100)
        raise NotImplementedError, "#{self.class}#app_logs"
      end
    end
  end
end
