#!/usr/bin/env ruby
# frozen_string_literal: true
# Import a completed blind review without changing the frozen test or train data.
require 'csv'
require 'digest'
require 'fileutils'
require 'json'

module ImportShellLiteralTestReview
  ROOT = File.expand_path('../..', __dir__)
  PACKAGE = File.join(ROOT, 'deliverables/2026-10-22/工具调用二分类门控-字面文本与执行对照-v0.11.0')
  DATA = File.join(PACKAGE, 'dataset')
  REVIEW = File.join(PACKAGE, '人工复核')
  SOURCE_CSV = File.join(REVIEW, '独立测试盲审.csv')
  MAPPING_JSON = File.join(REVIEW, '盲审映射与冻结标签.json')
  DEFAULT_OUTPUT = File.join(REVIEW, '已复核金标')
  COLUMNS = %w[blind_sample_id blind_pair_id command visible_user_context human_gate evidence reviewer].freeze

  def self.csv_rows(path)
    table = CSV.read(path, headers: true, encoding: 'bom|utf-8')
    raise 'Unexpected human review CSV columns' unless table.headers == COLUMNS

    table.map(&:to_h)
  end

  def self.build_gold_rows(source_rows:, annotated_rows:, mapping:, frozen_test_rows:)
    mappings = mapping.fetch('labels').to_h { |item| [item.fetch('blind_id'), item] }
    raise 'Duplicate blind ids in frozen mapping' unless mappings.size == mapping.fetch('labels').size
    source_by_id = source_rows.to_h { |item| [item.fetch('blind_sample_id'), item] }
    annotated_by_id = annotated_rows.to_h { |item| [item.fetch('blind_sample_id'), item] }
    raise 'Duplicate blind IDs in source CSV' unless source_by_id.size == source_rows.size
    raise 'Duplicate blind IDs in annotations' unless annotated_by_id.size == annotated_rows.size
    raise 'Source CSV IDs differ from frozen mapping' unless source_by_id.keys.sort == mappings.keys.sort
    raise 'Annotation IDs differ from source CSV' unless annotated_by_id.keys.sort == source_by_id.keys.sort

    frozen_by_id = frozen_test_rows.to_h { |item| [item.fetch('id'), item] }
    gold_rows = []
    disagreements = []
    annotated_by_id.each do |blind_id, annotation|
      original = source_by_id.fetch(blind_id)
      map_item = mappings.fetch(blind_id)
      %w[blind_pair_id command visible_user_context].each do |field|
        raise "Reviewer changed frozen field #{field}: #{blind_id}" unless annotation.fetch(field).to_s == original.fetch(field).to_s
      end
      gate = annotation.fetch('human_gate').to_s.strip
      raise "Invalid human gate for #{blind_id}" unless %w[allow needs_review].include?(gate)
      raise "Missing evidence for #{blind_id}" if annotation.fetch('evidence').to_s.strip.empty?
      raise "Missing reviewer ID for #{blind_id}" if annotation.fetch('reviewer').to_s.strip.empty?

      row = Marshal.load(Marshal.dump(frozen_by_id.fetch(map_item.fetch('source_id'))))
      raise "Frozen source mismatch for #{blind_id}" unless row['group_id'] == map_item.fetch('group_id')
      row['targets']['gate']['label'] = gate
      row['human_review'] = { 'blind_sample_id' => blind_id,
                              'evidence' => annotation.fetch('evidence').to_s.strip,
                              'reviewer' => annotation.fetch('reviewer').to_s.strip }
      gold_rows << row
      if gate != map_item.fetch('expected_gate')
        disagreements << { 'blind_sample_id' => blind_id,
                           'human_gate' => gate,
                           'policy_constructed_gate' => map_item.fetch('expected_gate') }
      end
    end
    [gold_rows, disagreements]
  end

  def self.import!(annotations_path:, output: DEFAULT_OUTPUT)
    raise 'Output already exists; refusing to overwrite human gold' if File.exist?(output)
    source_rows = csv_rows(SOURCE_CSV)
    annotated_rows = csv_rows(annotations_path)
    mapping = JSON.parse(File.read(MAPPING_JSON))
    test_path = File.join(DATA, 'locked_test_candidate.jsonl')
    actual_test_digest = Digest::SHA256.file(test_path).hexdigest
    raise 'Frozen test data digest differs from blind mapping' unless actual_test_digest == mapping.fetch('source_test_sha256')
    frozen_test_rows = File.foreach(test_path).map { |line| JSON.parse(line) }
    gold_rows, disagreements = build_gold_rows(source_rows: source_rows,
      annotated_rows: annotated_rows, mapping: mapping, frozen_test_rows: frozen_test_rows)
    raise 'Expected all 200 blind test annotations' unless gold_rows.size == 200

    FileUtils.mkdir_p(output)
    gold_path = File.join(output, 'human-gold-test.jsonl')
    File.write(gold_path, gold_rows.map { |row| JSON.generate(row) }.join("\n") + "\n")
    DiskTrial.json(File.join(output, 'human-review-audit.json'), {
      human_verified_rows: gold_rows.size, human_gold: true,
      gold_scope: 'human-reviewed synthetic locked-test subset; not real-history coverage',
      labels: gold_rows.group_by { |row| row.dig('targets', 'gate', 'label') }.transform_values(&:size),
      reviewer_ids: annotated_rows.map { |row| row.fetch('reviewer').strip }.uniq.sort,
      disagreement_with_constructed_policy: disagreements,
      source_test_sha256: actual_test_digest, production_qualified: false
    })
    File.chmod(0o600, gold_path)
    File.chmod(0o600, File.join(output, 'human-review-audit.json'))
    puts JSON.generate(human_verified_rows: gold_rows.size, disagreements: disagreements.size,
      production_qualified: false, output: output)
  end
end

require_relative 'shell_data'
if $PROGRAM_NAME == __FILE__
  arguments = ARGV.each_slice(2).to_h
  annotations = arguments.fetch('--annotations') { abort 'Usage: import_shell_literal_test_review.rb --annotations <completed.csv> [--output <directory>]' }
  ImportShellLiteralTestReview.import!(annotations_path: annotations,
    output: arguments.fetch('--output', ImportShellLiteralTestReview::DEFAULT_OUTPUT))
end
