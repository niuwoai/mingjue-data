#!/usr/bin/env ruby
# frozen_string_literal: true
require 'json'
require 'fileutils'
require 'digest'
require 'optparse'

options = { reviews: [] }
OptionParser.new do |p|
  p.on('--primary PATH') { |v| options[:primary] = v }
  p.on('--review PATH') { |v| options[:reviews] << v }
  p.on('--output DIR') { |v| options[:output] = v }
end.parse!
load_rows = ->(path) { File.foreach(path).map { |line| JSON.parse(line) } }
primary = load_rows.call(options.fetch(:primary)).to_h { |r| [r.fetch('sample_id'), r] }
all = options.fetch(:reviews).flat_map { |path| load_rows.call(path) }
merged = all.group_by { |r| r.fetch('sample_id') }.map do |_id, variants|
  disagree = variants.map { |r| r.values_at('risk', 'authorization', 'decision') }.uniq.size > 1
  variants.first.merge('repeat_disagreement' => disagree, 'repeat_review_count' => variants.size)
end
FileUtils.mkdir_p(options.fetch(:output), mode: 0o700)
File.open(File.join(options[:output], 'merged-review.jsonl'), 'w', 0o600) do |f|
  merged.each { |r| f.puts(JSON.generate(r)) }
end
matched = merged.select { |r| primary[r['sample_id']] }
axes = %w[risk authorization decision].to_h do |key|
  table = matched.group_by { |r| [primary[r['sample_id']][key], r[key]] }.transform_values(&:size)
  total = matched.size.to_f
  observed = total.zero? ? 0 : matched.count { |r| primary[r['sample_id']][key] == r[key] } / total
  labels = table.keys.flatten.uniq
  expected = total.zero? ? 0 : labels.sum do |label|
    first = matched.count { |r| primary[r['sample_id']][key] == label } / total
    second = matched.count { |r| r[key] == label } / total
    first * second
  end
  [key, { rows: total.to_i, agreement: observed, cohen_kappa: expected == 1 ? nil : (observed-expected)/(1-expected),
          confusion: table.map { |(a,b), n| { teacher: a, reviewer: b, rows: n } } }]
end
report = { reviewed_unique: merged.size, matched_to_primary: matched.size,
           repeated_review_disagreements: merged.count { |r| r['repeat_disagreement'] },
           all_three_axes_agreement: matched.count { |r| !r['repeat_disagreement'] && %w[risk authorization decision].all? { |k| primary[r['sample_id']][k] == r[k] } },
           axes: axes, primary_sha256: Digest::SHA256.file(options[:primary]).hexdigest,
           review_hashes: options[:reviews].to_h { |p| [p, Digest::SHA256.file(p).hexdigest] },
           human_reviewed: 0, note: 'AI blind review only. Kappa affected by class imbalance and targeted sample selection; not accuracy.' }
File.write(File.join(options[:output], 'review-report.json'), JSON.pretty_generate(report) + "\n", mode: 'w', perm: 0o600)
puts JSON.pretty_generate(report.reject { |k,_| k == :axes })
