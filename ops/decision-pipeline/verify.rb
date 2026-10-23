#!/usr/bin/env ruby
# frozen_string_literal: true
require 'open3'
require 'json'
require 'fileutils'
require 'time'

output = ARGV.fetch(0)
checks = [
  ['pipeline', ['ruby', File.join(__dir__, 'test_pipeline.rb')]],
  ['metrics', ['python3', '-m', 'unittest', 'discover', '-s', 'ops/decision-train', '-p', 'test_*.py']],
  ['training_syntax', ['python3', '-m', 'py_compile', 'ops/decision-train/train.py', 'ops/decision-train/data.py', 'ops/decision-train/challenge.py']]
].map do |name, command|
  stdout, stderr, status = Open3.capture3(*command)
  { name: name, command: command, exit_status: status.exitstatus, passed: status.success?, stdout: stdout, stderr: stderr }
end
FileUtils.mkdir_p(output, mode: 0o700)
report = { checked_at: Time.now.utc.iso8601, passed: checks.all? { |c| c[:passed] }, checks: checks }
File.write(File.join(output, '本地验证.json'), JSON.pretty_generate(report) + "\n", mode: 'w', perm: 0o600)
markdown = "# 本地验证\n\n时间：#{report[:checked_at]}\n\n" + checks.map do |c|
  "## #{c[:name]}\n\n结果：#{c[:passed] ? '通过' : '失败'}\n\n```text\n#{c[:stdout]}#{c[:stderr]}```\n"
end.join("\n")
File.write(File.join(output, '本地验证.md'), markdown, mode: 'w', perm: 0o600)
puts JSON.generate(passed: report[:passed], checks: checks.size)
exit(report[:passed] ? 0 : 1)
