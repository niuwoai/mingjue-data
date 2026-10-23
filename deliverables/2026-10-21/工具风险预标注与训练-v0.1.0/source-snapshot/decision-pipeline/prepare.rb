#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'ipaddr'

module DecisionData
  VERSION = '0.1.0'
  SOURCE = 'deliverables/2026-10-20/Codex命令调用10000条标注包/待标注样本10000条.jsonl'
  MANIFEST = 'deliverables/2026-10-20/Codex命令调用10000条标注包/抽样与分组清单.json'
  OUTPUT = 'deliverables/2026-10-21/工具风险预标注与训练-v0.1.0'

  class Sanitizer
    attr_reader :counts

    def initialize
      @counts = Hash.new(0)
    end

    def substitute(text, pattern, category)
      text.gsub(pattern) do |value|
        @counts[category] += 1
        block_given? ? yield(value) : "[#{category.upcase}_#{Digest::SHA256.hexdigest(value)[0, 8]}]"
      end
    end

    def clean(text)
      value = text.to_s.dup
      value = substitute(value, /-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----/m, 'private_key')
      value = substitute(value, /\b(?:sk-(?:proj-)?|gh[pousr]_|github_pat_|xox[baprs]-)[A-Za-z0-9_-]{12,}\b/, 'credential')
      value = substitute(value, /\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/, 'jwt')
      value = substitute(value, /(?:Bearer|Basic)\s+[A-Za-z0-9+\/_=.:-]{8,}/i, 'auth_header')
      value = redact_assignments(value)
      value = substitute(value, %r{(?<=://)[^\s/:@]+:[^\s/@]+@}, 'url_credentials')
      value = substitute(value, /[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/, 'email')
      value = substitute(value, %r{/(?:Users|home)/[A-Za-z0-9_.-]+}, 'user_home')
      value
    end

    def redact_assignments(value)
      pattern = /((?:[A-Z_]*(?:API_KEY|AUTH_TOKEN|ACCESS_TOKEN|PASSWORD|SECRET)|(?:api[_-]?key|auth[_-]?token|access[_-]?token|password|secret|auth\.token))\s*["']?\s*[:=]\s*["']?)([^\s"'`,;}]{6,})/i
      value.gsub(pattern) do
        prefix, secret = Regexp.last_match(1), Regexp.last_match(2)
        next "#{prefix}#{secret}" if secret.start_with?('$', '[', '<') || secret.match?(/\A(?:true|false|null|unknown)\z/i)

        @counts['secret_assignment'] += 1
        "#{prefix}[SECRET_#{Digest::SHA256.hexdigest(secret)[0, 8]}]"
      end
    end
  end

  def self.export_record(row, sanitizer)
    {
      sample_id: row.fetch('sample_id'),
      group_id: row.fetch('group_id'),
      split: row.fetch('proposed_split'),
      pilot_related_group: row.fetch('pilot_related_group'),
      state: {
        command: sanitizer.clean(row.fetch('command')),
        cwd: sanitizer.clean(row.fetch('cwd')),
        visible_user_context_candidates: row.fetch('preceding_user_records').map { |u| sanitizer.clean(u.fetch('text')) },
        requested_sandbox_permissions: row['requested_sandbox_permissions'],
        approval_justification: sanitizer.clean(row['approval_justification'])
      }
    }
  end

  def self.validate_groups(rows)
    raise 'Duplicate sample IDs' unless rows.map { |r| r[:sample_id] }.uniq.size == rows.size

    rows.group_by { |r| r[:group_id] }.each_value do |group|
      raise 'Group crosses split boundary' unless group.map { |r| r[:split] }.uniq.size == 1
      if group.any? { |r| r[:pilot_related_group] }
        raise 'Pilot-related group entered held-out data' unless %w[train development].include?(group.first[:split])
      end
    end
  end

  def self.run(source: SOURCE, manifest: MANIFEST, output: OUTPUT)
    original = JSON.parse(File.read(manifest))
    raise 'Original source hash changed' unless Digest::SHA256.file(source).hexdigest == original.fetch('jsonl_sha256')

    sanitizer = Sanitizer.new
    rows = File.foreach(source).map { |line| export_record(JSON.parse(line), sanitizer) }
    validate_groups(rows)
    FileUtils.mkdir_p(output, mode: 0o700)
    path = File.join(output, 'prepared.jsonl')
    File.open(path, 'w', 0o600) { |file| rows.each { |row| file.puts(JSON.generate(row)) } }
    report = report_for(rows, sanitizer, source, path)
    File.write(File.join(output, 'preparation.json'), JSON.pretty_generate(report) + "\n", mode: 'w', perm: 0o600)
    puts JSON.pretty_generate(report)
  end

  def self.report_for(rows, sanitizer, source, path)
    {
      version: VERSION, rows: rows.size, groups: rows.map { |r| r[:group_id] }.uniq.size,
      source_sha256: Digest::SHA256.file(source).hexdigest,
      prepared_sha256: Digest::SHA256.file(path).hexdigest,
      splits: rows.group_by { |r| r[:split] }.transform_values(&:size),
      redactions: sanitizer.counts, group_isolation_verified: true,
      labels_in_model_input: false, historical_commands_executed: 0,
      caveat: 'Additional pattern scanning and sample privacy review are required before external annotation.'
    }
  end
end

DecisionData.run if $PROGRAM_NAME == __FILE__
