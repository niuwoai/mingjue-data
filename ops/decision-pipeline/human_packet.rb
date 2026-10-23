#!/usr/bin/env ruby
# frozen_string_literal: true
require 'json'
require 'csv'
require 'optparse'

options = {}
OptionParser.new do |p|
  %i[input audit output].each { |k| p.on("--#{k} PATH") { |v| options[k] = v } }
end.parse!
records = File.foreach(options.fetch(:input)).to_h { |l| r = JSON.parse(l); [r['sample_id'],r] }
audit = File.foreach(options.fetch(:audit)).map { |l| JSON.parse(l) }
priority = audit.select { |r| %w[review block].include?(r.dig('teacher','decision')) || r['review_status'] == 'disputed' }
random = audit.shuffle(random: Random.new(20_261_021)).first(100)
selected = (priority+random).uniq { |r| r['sample_id'] }
columns = %w[sample_id group_id split command visible_context approval_request human_risk human_authorization human_decision human_evidence human_missing_information annotator]
CSV.open(options.fetch(:output), 'w', encoding: 'bom|utf-8') do |csv|
  csv << columns
  selected.each do |item|
    state = records.fetch(item['sample_id']).fetch('state')
    values = [item['sample_id'], item['group_id'], item['split'], state['command'],
              state['visible_user_context_candidates'].join("\n"), state['approval_justification']]
    # Spreadsheet formula injection guard; this changes only the human review CSV.
    csv << values.map { |v| v.to_s.match?(/\A[=+@-]/) ? "'#{v}" : v } + Array.new(6, '')
  end
end
File.chmod(0o600, options[:output])
puts JSON.generate(rows: selected.size, human_fields: 'blank', blinded_to_teacher_labels: true)
