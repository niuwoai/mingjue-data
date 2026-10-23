require_relative 'augment'

labels_path = File.join(OUT, 'policy-review-astra/labels.jsonl')
review = File.readlines(labels_path).map { |l| JSON.parse(l) }
selected = File.readlines(File.join(OUT, 'policy-review-input.jsonl')).map { |l| JSON.parse(l) }
raise 'Independent review incomplete' unless review.map { |r| r['sample_id'] }.sort == selected.map { |r| r['sample_id'] }.sort
audit = File.readlines(File.join(OUT, 'synthetic-label-audit.jsonl')).map { |l| JSON.parse(l) }.to_h { |r| [r['id'], r] }
disputes = review.select do |r|
  decision = %w[review block].include?(r['decision']) ? 'needs_review' : r['decision']
  decision != audit.fetch(r['sample_id'])['action']
end
families = disputes.map { |r| audit.fetch(r['sample_id'])['family'] }.uniq.sort
raise 'Already finalized' if File.exist?(File.join(OUT, 'candidate-dataset'))
FileUtils.cp_r(File.join(OUT, 'dataset'), File.join(OUT, 'candidate-dataset'))
manifest = JSON.parse(File.read(File.join(OUT, 'dataset/manifest.json')))
manifest['candidate_manifest_sha256'] = Digest::SHA256.file(File.join(OUT, 'candidate-dataset/manifest.json')).hexdigest
manifest['reviewed_synthetic_rows'] = review.size
manifest['quarantined_operation_families'] = families
manifest['review_policy'] = 'Quarantine whole synthetic operation family if any reviewed action disagrees or is unknown; no relabelling unknown as harmful.'
manifest['splits'].each_key do |split|
  path = File.join(OUT, 'dataset', split + '.jsonl')
  rows = File.readlines(path).map { |l| JSON.parse(l) }.reject do |r|
    families.include?(r['group_id'].delete_prefix('synthetic-operation-family:'))
  end
  write_rows(path, rows)
  synthetic = rows.select { |r| r['id'].start_with?('SYN2-') }
  manifest['splits'][split] = {rows: rows.size, positives: rows.count { |r| r.dig('targets','gate','label') == 'needs_review' },
    synthetic_rows: synthetic.size, synthetic_positives: synthetic.count { |r| r.dig('targets','gate','label') == 'needs_review' },
    sha256: Digest::SHA256.file(path).hexdigest}
end
manifest['labels'] = manifest['splits'].values.sum { |s| s[:rows] }
write_json(File.join(OUT, 'dataset/manifest.json'), manifest)
write_json(File.join(OUT, '独立复核与家族隔离.json'), {reviewed: review.size, disputes: disputes,
  quarantined_families: families, human_verified: false, remaining_rows: manifest['labels']})
puts JSON.generate(reviewed: review.size, disputes: disputes.size, quarantined_families: families, final_rows: manifest['labels'])
