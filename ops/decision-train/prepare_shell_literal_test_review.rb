#!/usr/bin/env ruby
# frozen_string_literal: true
# Produce a blind human-review sample from the untouched v0.11 locked test.
require 'csv'
require 'digest'
require 'fileutils'
require 'json'

module ShellLiteralTestReview
  ROOT = File.expand_path('../..', __dir__)
  PACKAGE = File.join(ROOT, 'deliverables/2026-10-22/工具调用二分类门控-字面文本与执行对照-v0.11.0')
  DATA = File.join(PACKAGE, 'dataset')
  OUT = File.join(PACKAGE, '人工复核')
  GROUPS = 100

  def self.rows(path)
    File.foreach(path).map { |line| JSON.parse(line) }
  end

  def self.blind_key(value)
    Digest::SHA256.hexdigest("rsi-human-review-v1:#{value}")[0, 16]
  end

  def self.safe_cell(value)
    text = value.to_s
    text.match?(/\A[=+@-]/) ? "'#{text}" : text
  end

  def self.build
    raise 'Output already exists; refusing to overwrite review material' if File.exist?(OUT)
    test_rows = rows(File.join(DATA, 'locked_test_candidate.jsonl'))
    manifest = JSON.parse(File.read(File.join(DATA, 'manifest.json')))
    raise 'Test split does not match frozen manifest' unless test_rows.size == manifest.dig('splits', 'locked_test_candidate', 'rows')
    groups = test_rows.group_by { |row| row.fetch('group_id') }
    raise 'Expected 600 paired test groups' unless groups.size == 600 && groups.values.all? { |pair| pair.size == 2 }
    selected = groups.keys.sort_by { |group| Digest::SHA256.hexdigest("human-v1:#{group}") }.first(GROUPS)
    mapping = []
    review_rows = []
    selected.each do |group|
      blind_group = "PAIR-#{blind_key(group)}"
      groups.fetch(group).sort_by { |row| blind_key(row.fetch('id')) }.each do |row|
        blind_id = "SAMPLE-#{blind_key(row.fetch('id'))}"
        state = row.fetch('state')
        review_rows << [blind_id, blind_group, safe_cell(state['command']),
                        safe_cell(Array(state['visible_user_context_candidates']).join("\n")), '', '', '']
        mapping << { blind_id: blind_id, source_id: row.fetch('id'), group_id: group,
                     expected_gate: row.dig('targets', 'gate', 'label') }
      end
    end

    FileUtils.mkdir_p(OUT)
    CSV.open(File.join(OUT, '独立测试盲审.csv'), 'w', encoding: 'bom|utf-8') do |csv|
      csv << %w[blind_sample_id blind_pair_id command visible_user_context human_gate evidence reviewer]
      review_rows.each { |fields| csv << fields }
    end
    mapping_path = File.join(OUT, '盲审映射与冻结标签.json')
    File.write(mapping_path, JSON.pretty_generate({
      source_split: 'locked_test_candidate', source_manifest_sha256: Digest::SHA256.file(File.join(DATA, 'manifest.json')).hexdigest,
      source_test_sha256: manifest.dig('splits', 'locked_test_candidate', 'sha256'),
      sampled_pairs: selected.size, rows: mapping.size, labels: mapping
    }) + "\n")
    File.chmod(0o600, mapping_path)
    File.chmod(0o600, File.join(OUT, '独立测试盲审.csv'))
    puts JSON.generate(rows: review_rows.size, paired_groups: selected.size, labels_hidden: true,
                       source_split: 'locked_test_candidate', human_gold: 0)
  end
end

ShellLiteralTestReview.build if $PROGRAM_NAME == __FILE__
