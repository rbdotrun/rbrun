# frozen_string_literal: true

require "minitest/autorun"
require "webmock/minitest"
require "rbrun/sandbox"

# Provider clients are tested against a stubbed WIRE, never a hand-rolled fake client. Any unstubbed
# outbound request is a test bug, so fail loudly rather than reach the network.
WebMock.disable_net_connect!
