require "test_helper"
require "capybara/cuprite"

# Headless Chrome via Cuprite (ferrum) — the same driver the browser dogfood uses. js_errors: true so
# a client-side bug surfaces as a test failure instead of silent "nothing happens".
RBRUN_CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
Capybara.register_driver(:rbrun_system) do |app|
  Capybara::Cuprite::Driver.new(app,
    headless: true, js_errors: true, window_size: [ 1400, 1000 ],
    browser_path: (File.exist?(RBRUN_CHROME) ? RBRUN_CHROME : nil),
    process_timeout: 40, timeout: 30)
end
Capybara.default_max_wait_time = 8
Capybara.save_path = Rails.root.join("tmp/screenshots").to_s

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :rbrun_system
end
