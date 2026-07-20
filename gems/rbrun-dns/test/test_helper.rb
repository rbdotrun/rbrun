# frozen_string_literal: true

require "minitest/autorun"
require "webmock/minitest"
require "rbrun/dns"

# Provider adapters are tested by driving the REAL client against a stubbed WIRE — never a hand fake.
WebMock.disable_net_connect!
