require "sshkey"

module Rbrun
  # Generates + stores the SSH keypair WE own for a deployment — one per deploy target (per worktree). The
  # public half is uploaded to the provider and attached to the server; the private half authenticates the
  # Kamal deploy. Generated with the sshkey gem (pure Ruby, no shelling out). Idempotent: a target that
  # already has a keypair keeps it, so re-provisioning never rotates the key out from under a live server.
  class DeployKeys
    # Ensure the target has a keypair; returns it as [public, private].
    def self.ensure!(target)
      if target.ssh_public_key.blank? || target.ssh_private_key.blank?
        key = SSHKey.generate(type: "RSA", bits: 4096, comment: "rbrun-w#{target.worktree_id}")
        target.update!(ssh_public_key: key.ssh_public_key, ssh_private_key: key.private_key)
      end
      [ target.ssh_public_key, target.ssh_private_key ]
    end
  end
end
