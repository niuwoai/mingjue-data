#!/usr/bin/env ruby
# frozen_string_literal: true

require 'csv'
require 'digest'
require 'json'

module HistoricalGoldQueue
  ROOT = File.expand_path('../..', __dir__)
  SOURCE = File.join(ROOT, 'deliverables/2026-10-20/Codex命令调用10000条标注包/待标注样本10000条.jsonl')
  PILOT = File.join(ROOT, 'deliverables/2026-10-20/Codex命令调用1000条试标/样本-脱敏上下文.jsonl')
  PILOT_CSV = File.join(ROOT, 'deliverables/2026-10-20/Codex命令调用1000条试标/试标审核表.csv')
  DATASET_ROOT = File.join(ROOT, 'deliverables')
  OUTPUT = File.join(ROOT, 'deliverables/2026-10-22/工具调用4B扩展命令族-v0.10.0/历史工具调用人工盲审.csv')
  AUDIT = File.join(ROOT, 'deliverables/2026-10-22/工具调用4B扩展命令族-v0.10.0/历史盲审抽样审计.json')
  SAMPLE_LIMIT = 400
  PER_SESSION_LIMIT = 4
  SEED = 20_261_022
  HELDOUT_PROPOSED_SPLITS = %w[train development threshold_validation calibration].freeze
  DATASET_SPLITS = %w[train development calibration threshold_validation locked_test_candidate regression].freeze
  COLUMNS = %w[
    sample_id source tool_family command working_directory_kind visible_user_context
    requested_sandbox_permissions approval_justification human_gate human_risk
    human_authorization human_information_sufficiency human_evidence confidence annotator_id
  ].freeze

  class << self
    def jsonl(path)
      File.foreach(path).map { |line| JSON.parse(line) }
    end

    def digest(text)
      Digest::SHA256.hexdigest(text.to_s)
    end

    def safe_text(value, counts)
      text = value.to_s.dup
      text.gsub!(/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/m) do
        counts[:private_key] += 1
        '<PRIVATE_KEY_REDACTED>'
      end
      text.gsub!(/\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})\b/) do
        counts[:credential] += 1
        '<CREDENTIAL_REDACTED>'
      end
      text.gsub!(/\bBearer\s+\S+/i) do
        counts[:bearer] += 1
        'Bearer <CREDENTIAL_REDACTED>'
      end
      text.gsub!(/\b((?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|passwd)\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s;,]+)/i) do
        counts[:credential_assignment] += 1
        "#{$1}<CREDENTIAL_REDACTED>"
      end
      text.gsub!(/[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/) do
        counts[:email] += 1
        '<EMAIL_REDACTED>'
      end
      text.gsub!(/(?<!\d)1[3-9]\d{9}(?!\d)/) do
        counts[:phone] += 1
        '<PHONE_REDACTED>'
      end
      text.gsub!(%r{/(?:Users|home)/[^/\s"'`]+(?:/[^\s"'`]+)*}) do
        counts[:user_path] += 1
        '<USER_PATH>'
      end
      text.gsub!(/~\/[^\s"'`]+/) do
        counts[:home_path] += 1
        '<HOME_PATH>'
      end
      text.gsub!(/\b(?:\d{1,3}\.){3}\d{1,3}\b/) do
        counts[:ip_address] += 1
        '<IP_REDACTED>'
      end
      text[0, 2_500]
    end

    def working_directory_kind(path)
      value = path.to_s
      return 'home_or_workspace' if value.start_with?('~', '/Users/', '/home/')
      return 'temporary' if value.start_with?('/tmp/', '/var/tmp/')
      return 'system' if value.start_with?('/etc/', '/var/', '/usr/', '/opt/', '/dev/')
      return 'unknown' if value.empty?

      'other'
    end

    def dataset_exclusions
      sessions = {}
      commands = {}
      dataset_dirs = Dir.glob(File.join(DATASET_ROOT, '**', 'dataset')).select do |directory|
        File.file?(File.join(directory, 'train.jsonl'))
      end
      dataset_dirs.each do |directory|
        DATASET_SPLITS.each do |split|
          path = File.join(directory, "#{split}.jsonl")
          next unless File.file?(path)

          jsonl(path).each do |row|
          sessions[row['group_id'].to_s] = true
          commands[digest(row.dig('state', 'command'))] = true
          end
        end
      end
      [sessions, commands]
    end

    def pilot_exclusions
      rows = jsonl(PILOT)
      sessions = rows.map { |row| row['session_id'].to_s }.to_h { |value| [value, true] }
      commands = rows.map { |row| digest(row['command']) }.to_h { |value| [value, true] }
      [sessions, commands]
    end

    def candidates
      sessions, commands = dataset_exclusions
      pilot_sessions, pilot_commands = pilot_exclusions
      excluded = Hash.new(0)
      rows = jsonl(SOURCE).select { |row| HELDOUT_PROPOSED_SPLITS.include?(row['proposed_split']) }
      kept = rows.reject do |row|
        reason = if sessions[row['session_id'].to_s] || pilot_sessions[row['session_id'].to_s]
                   :overlapping_session
                 elsif commands[digest(row['command'])] || pilot_commands[digest(row['command'])]
                   :overlapping_command
                 elsif row['command_truncated']
                   :truncated_command
                 end
        excluded[reason] += 1 if reason
        reason
      end
      [kept, excluded]
    end

    def sample(rows)
      rng = Random.new(SEED)
      buckets = rows.group_by do |row|
        command = row['command'].to_s.strip
        family = command[/\A(?:env\s+)?(?:sudo\s+)?([A-Za-z0-9_.+-]+)/, 1] || 'unknown'
        context = Array(row['preceding_user_records']).any? { |record| !record['text'].to_s.strip.empty? }
        [family.downcase, context]
      end
      queues = buckets.keys.sort_by { |family, has_context| [family, has_context ? 1 : 0] }
                      .map { |key| buckets.fetch(key).shuffle(random: rng) }
      result = []
      session_counts = Hash.new(0)
      loop do
        added = false
        queues.each do |queue|
          candidate = queue.find do |row|
            session_counts[row['session_id'].to_s] < PER_SESSION_LIMIT
          end
          next unless candidate

          queue.delete(candidate)
          session = candidate['session_id'].to_s
          session_counts[session] += 1
          result << candidate
          added = true
          return result if result.length >= SAMPLE_LIMIT
        end
        break unless added
      end
      result
    end

    def export_row(row, number, redactions)
      context = Array(row['preceding_user_records']).last(3).map { |record| record['text'] }.compact.join("\n---\n")
      {
        'sample_id' => format('HIST-%04d', number),
        'source' => 'Codex',
        'tool_family' => row['command'].to_s[/\A(?:env\s+)?(?:sudo\s+)?([A-Za-z0-9_.+-]+)/, 1].to_s.downcase,
        'command' => safe_text(row['command'], redactions),
        'working_directory_kind' => working_directory_kind(row['cwd']),
        'visible_user_context' => safe_text(context, redactions),
        'requested_sandbox_permissions' => safe_text(row['requested_sandbox_permissions'], redactions),
        'approval_justification' => safe_text(row['approval_justification'], redactions),
        'human_gate' => '', 'human_risk' => '', 'human_authorization' => '',
        'human_information_sufficiency' => '', 'human_evidence' => '', 'confidence' => '', 'annotator_id' => ''
      }
    end

    def build
      eligible, excluded = candidates
      selected = sample(eligible)
      raise "Insufficient independent rows: #{selected.length}" if selected.length < 80

      redactions = Hash.new(0)
      exported = selected.each_with_index.map { |row, index| export_row(row, index + 1, redactions) }
      unsafe = exported.count do |row|
        row.values.any? { |value| value.match?(/(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|Bearer\s+[^<]|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|(?<!\d)1[3-9]\d{9}(?!\d))/i) }
      end
      raise "Sensitive pattern remains in #{unsafe} exported rows" unless unsafe.zero?

      CSV.open(OUTPUT, 'w', encoding: 'bom|utf-8') do |csv|
        csv << COLUMNS
        exported.each { |row| csv << COLUMNS.map { |column| row.fetch(column) } }
      end
      File.chmod(0o600, OUTPUT)
      audit = {
        'source_rows' => 10_000, 'source' => 'Codex historical tool calls',
        'all_known_experiment_dataset_dirs_excluded' => Dir.glob(File.join(DATASET_ROOT, '**', 'dataset')).count do |directory|
          File.file?(File.join(directory, 'train.jsonl'))
        end,
        'proposed_split_filter' => HELDOUT_PROPOSED_SPLITS,
        'eligible_after_overlap_and_truncation_exclusion' => eligible.length,
        'excluded' => excluded.transform_keys(&:to_s), 'sampled_rows' => selected.length,
        'unique_source_sessions' => selected.map { |row| row['session_id'] }.uniq.length,
        'max_rows_per_source_session' => selected.group_by { |row| row['session_id'] }.values.map(&:length).max,
        'training_or_regression_overlap' => false, 'model_outputs_or_weak_labels_exported' => false,
        'sensitive_patterns_remaining' => unsafe, 'redaction_counts' => redactions.transform_keys(&:to_s),
        'human_gold_rows' => 0, 'commands_executed' => false
      }
      File.write(AUDIT, JSON.pretty_generate(audit) + "\n")
      File.chmod(0o600, AUDIT)
      puts JSON.generate(audit)
    end
  end
end

HistoricalGoldQueue.build if $PROGRAM_NAME == __FILE__
