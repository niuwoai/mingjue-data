require_relative 'shell_scale_data'
require_relative '../decision-pipeline/labels'

root = ShellScale::OUT
train_new = DiskTrial.rows(File.join(root, 'new-train-candidates.jsonl'))
test_new = DiskTrial.rows(File.join(root, 'new-test-candidates.jsonl'))
review_rows = DiskTrial.rows(File.join(root, 'review-input.jsonl'))
reviewed = DiskTrial.rows(File.join(root, 'independent-review/labels.jsonl'))
raise 'Review IDs differ from the stratified review plan' unless reviewed.map { |r| r['sample_id'] }.sort == review_rows.map { |r| r['sample_id'] }.sort
candidate_by_id = (train_new + test_new).to_h { |r| [r['id'], r] }
mapping = { 'allow' => 'allow', 'review' => 'needs_review', 'block' => 'needs_review' }
disagreements = reviewed.filter_map do |label|
  row = candidate_by_id.fetch(label['sample_id'])
  audited = row.dig('targets', 'gate', 'label')
  next if mapping[label['decision']] == audited
  { sample_id: label['sample_id'], audited: audited, independent_decision: label['decision'],
    family: row['group_id'], evidence: label['evidence'], missing_information: label['missing_information'] }
end
DiskTrial.json(File.join(root, '复核分歧.json'), { reviewed: reviewed.size, disagreements: disagreements, human_gold: 0 })
raise 'Resolve or quarantine every reviewed disagreement before freezing' unless disagreements.empty?

previous_data = File.join(ShellScale::PREVIOUS, 'dataset')
previous_train = DiskTrial.rows(File.join(previous_data, 'train.jsonl'))
raise 'Previous frozen train must remain 6000' unless previous_train.size == 6000
train = previous_train + train_new
test = test_new
splits = { 'train' => train, 'locked_test_candidate' => test }
%w[development calibration threshold_validation].each do |split|
  splits[split] = DiskTrial.rows(File.join(previous_data, split + '.jsonl'))
end
raise 'Train must contain 10000 rows and 5000 positives' unless train.size == 10_000 && train.count { |r| r.dig('targets', 'gate', 'label') == 'needs_review' } == 5_000
raise 'New test must contain 1200 rows and 600 positives' unless test.size == 1_200 && test.count { |r| r.dig('targets', 'gate', 'label') == 'needs_review' } == 600

seen_ids = {}
seen_states = {}
seen_groups = {}
splits.each do |split, rows|
  rows.each do |row|
    raise "Duplicate ID: #{row['id']}" if seen_ids[row['id']]
    seen_ids[row['id']] = split
    state = JSON.generate(row['state'])
    raise "Duplicate input across splits: #{row['id']}" if seen_states[state]
    seen_states[state] = split
    group = row['group_id']
    raise "Family crosses splits: #{group}" if seen_groups[group] && seen_groups[group] != split
    seen_groups[group] = split
  end
end
previous_test = DiskTrial.rows(File.join(previous_data, 'locked_test_candidate.jsonl'))
raise 'Previous test input leaked into the new training set' if previous_test.any? { |r| seen_states[JSON.generate(r['state'])] == 'train' }
raise 'New holdout family overlaps training' if test.any? { |r| seen_groups[r['group_id']] == 'train' }

dataset = File.join(root, 'dataset')
raise 'Frozen dataset already exists' if File.exist?(dataset)
FileUtils.mkdir_p(dataset)
manifest = { version: '0.7.0', experiment: 'shell_redirect_10000_v7', human_verified_rows: 0,
  independent_review_rows: reviewed.size, label_source: 'policy-derived synthetic with stratified independent model audit',
  split_protocol: 'All newly held-out wrapper families are test-only; old v0.6 development/calibration/threshold rows retained; synthetic, not human gold',
  previous_train_sha256: Digest::SHA256.file(File.join(previous_data, 'train.jsonl')).hexdigest,
  new_train_sha256: Digest::SHA256.file(File.join(root, 'new-train-candidates.jsonl')).hexdigest,
  new_test_sha256: Digest::SHA256.file(File.join(root, 'new-test-candidates.jsonl')).hexdigest,
  review_sha256: Digest::SHA256.file(File.join(root, 'independent-review/labels.jsonl')).hexdigest, splits: {} }
splits.each do |split, rows|
  path = File.join(dataset, split + '.jsonl')
  DiskTrial.jsonl(path, rows)
  manifest[:splits][split] = { rows: rows.size,
    positives: rows.count { |r| r.dig('targets', 'gate', 'label') == 'needs_review' },
    sha256: Digest::SHA256.file(path).hexdigest }
end
regression = DiskTrial.rows(File.join(previous_data, 'regression.jsonl'))
DiskTrial.jsonl(File.join(dataset, 'regression.jsonl'), regression)
manifest[:regression] = { rows: regression.size, sha256: Digest::SHA256.file(File.join(dataset, 'regression.jsonl')).hexdigest }
DiskTrial.json(File.join(dataset, 'manifest.json'), manifest)
DiskTrial.json(File.join(root, '数据审计.json'), { passed: true, train_rows: train.size, train_positive: 5_000,
  added_train_rows: 4_000, added_train_synthetic: 4_000, prior_train_rows_retained: 6_000,
  locked_test_rows: test.size, locked_test_positive: 600, new_test_synthetic: 1_200,
  independent_model_review_rows: reviewed.size, independent_model_disagreements: 0,
  human_gold: 0, regression_rows: regression.size, commands_executed: false,
  validation_splits_retained_from_v06: true, split_family_disjoint: true })
puts JSON.generate(train: train.size, train_positive: 5_000, new_test: test.size,
  test_positive: 600, reviewed: reviewed.size, human_gold: 0)
