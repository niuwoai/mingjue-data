#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require 'optparse'

options = { input: 'deliverables/2026-10-21/工具风险预标注与训练-v0.1.0/prepared.jsonl' }
OptionParser.new do |parser|
  parser.on('--input PATH') { |v| options[:input] = v }
  parser.on('--labels PATH') { |v| options[:labels] = v }
  parser.on('--output PATH') { |v| options[:output] = v }
  parser.on('--pilot') { options[:pilot] = true }
  parser.on('--fixed') { options[:fixed] = true }
  parser.on('--supplemental') { options[:supplemental] = true }
  parser.on('--existing PATH') { |v| options[:existing] = v }
end.parse!
abort '--labels and --output required' unless options[:labels] && options[:output]

records = File.foreach(options[:input]).to_h { |line| row = JSON.parse(line); [row.fetch('sample_id'), row] }
labels = File.foreach(options[:labels]).map { |line| JSON.parse(line) }
selection = if options[:supplemental]
              flagged = labels.select { |r| %w[high critical].include?(r['risk']) || r['authorization'] == 'out_of_scope' || %w[review block].include?(r['decision']) }
              risky_syntax = records.values.select { |r| r.dig('state', 'command').match?(/\brm\s+[^\n]*-[a-zA-Z]*[rf]|\bmkfs\b|\bDROP\s+(?:TABLE|DATABASE)\b|\bTRUNCATE\b|\bgit\s+push\b/i) }.shuffle(random: Random.new(42)).first(200)
              (flagged.map { |r| r['sample_id'] } + risky_syntax.map { |r| r['sample_id'] }).uniq
            elsif options[:fixed]
              heldout = records.values.select { |r| r['split'] == 'locked_test_candidate' }
              other = records.values.reject { |r| r['split'] == 'locked_test_candidate' }
              (heldout + other.shuffle(random: Random.new(20_261_021)).first(600)).map { |r| r['sample_id'] }
            elsif options[:pilot]
              labels.map { |row| row.fetch('sample_id') }
            else
              heldout = labels.select { |row| records.fetch(row['sample_id'])['split'] == 'locked_test_candidate' }
              development = labels.reject { |row| records.fetch(row['sample_id'])['split'] == 'locked_test_candidate' }
              flagged = development.select { |row| %w[high critical].include?(row['risk']) || row['authorization'] == 'out_of_scope' || row['decision'] == 'block' }
              review = development.select { |row| row['decision'] == 'review' }.shuffle(random: Random.new(2)).first(400)
              random = development.shuffle(random: Random.new(20_261_021)).first(600)
              (heldout + flagged + review + random).map { |row| row.fetch('sample_id') }.uniq
            end
if options[:existing]
  already = File.foreach(options[:existing]).map { |l| JSON.parse(l).fetch('sample_id') }
  selection -= already
end

File.open(options[:output], 'w', 0o600) do |file|
  selection.each { |id| file.puts(JSON.generate(records.fetch(id))) }
end
report = { rows: selection.size, selected_ids_sha256: Digest::SHA256.hexdigest(selection.sort.join("\n")),
           input_sha256: Digest::SHA256.file(options[:input]).hexdigest, primary_labels_sha256: Digest::SHA256.file(options[:labels]).hexdigest,
           reviewer_blinded_to_primary_labels: true, human_review: false,
           selection: options[:supplemental] ? 'all teacher high/critical/out-of-scope/review/block plus up to 200 destructive/push syntax candidates; syntax used only for sampling, not labels' : (options[:fixed] ? 'all 894 held-out candidates and 600 seeded random non-test records selected independently of labels' : (options[:pilot] ? 'all development pilot labels' : 'all held-out test candidates, all high/critical/out-of-scope/block, plus up to 400 review and 600 seeded random rows')) }
File.write(options[:output] + '.manifest.json', JSON.pretty_generate(report) + "\n", mode: 'w', perm: 0o600)
puts JSON.pretty_generate(report)
