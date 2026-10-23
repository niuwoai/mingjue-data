require_relative 'disk_data'
include DiskTrial

review = DiskTrial.rows(File.join(DiskTrial::OUT,'independent-review/labels.jsonl'))
input = DiskTrial.rows(File.join(DiskTrial::OUT,'review-input.jsonl'))
raise 'Review incomplete' unless review.map { |r| r['sample_id'] }.sort == input.map { |r| r['sample_id'] }.sort
audit = DiskTrial.rows(File.join(DiskTrial::OUT,'synthetic-label-audit.jsonl')).to_h { |r| [r['id'],r] }
disputes = review.select { |r| (%w[review block].include?(r['decision']) ? 'needs_review' : r['decision']) != audit.fetch(r['sample_id'])['label'] }
excluded = disputes.map { |r| audit.fetch(r['sample_id'])['family'] }.uniq
candidates = DiskTrial.rows(File.join(DiskTrial::OUT,'candidates.jsonl')).reject { |r| excluded.include?(r['group_id']) }
old = DiskTrial.rows(File.join(DiskTrial::OLD,'dataset/train.jsonl'))
long = JSON.parse(File.read(File.join(DiskTrial::FIRST,'trial-001/data-audit.json')))['train']['excluded'].map { |r| r['id'] }
real = DiskTrial.rows(File.join(DiskTrial::FIRST,'dataset/train.jsonl')).reject { |r| long.include?(r['id']) }
positive = real.select { |r| r.dig('targets','gate','label') == 'needs_review' }
old_real = old.select { |r| r['id'].start_with?('CDX10-') && r.dig('targets','gate','label') == 'allow' && !long.include?(r['id']) }
negative = old_real + real.select { |r| r.dig('targets','gate','label') == 'allow' && !old_real.any? { |o| o['id']==r['id'] } }.shuffle(random:Random.new(20261022)).first(800-old_real.size)
train = positive + negative + old.select { |r| r['id'].start_with?('SYN2-') }
raise 'Expected retained seed corpus' unless train.size == 1568
seed_count = train.size
duplicate_inputs = train.group_by { |r| JSON.generate(r['state']) }
conflicting = duplicate_inputs.select { |_,rows| rows.map { |r| r.dig('targets','gate','label') }.uniq.size > 1 }
train = duplicate_inputs.reject { |key,_| conflicting.key?(key) }.values.map(&:first)
deduplicated_seed_rows = seed_count-train.size
%w[allow needs_review].each do |label|
  needed = 2000-train.count { |r| r.dig('targets','gate','label') == label }
  pool = candidates.select { |r| r['split']=='train' && r.dig('targets','gate','label') == label }
  buckets = pool.group_by { |r| a=audit.fetch(r['id']); [a['recipe'],a['variant']] }.values
  rng = Random.new(label=='allow' ? 221 : 222)
  buckets.each { |b| b.shuffle!(random:rng) }
  picked = []
  while picked.size < needed
    available = buckets.select { |b| !b.empty? }
    raise 'Too many quarantined families; insufficient reviewed candidate coverage' if available.empty?
    available.each { |b| picked << b.pop if picked.size < needed }
  end
  train.concat(picked)
end
dataset = File.join(DiskTrial::OUT,'dataset')
raise 'Final dataset already frozen' if File.exist?(File.join(dataset,'manifest.json'))
FileUtils.mkdir_p(dataset)
sets = {'train'=>train}
DiskTrial::SPLITS.drop(1).each { |split| sets[split]=candidates.select { |r| r['split']==split } }
manifest = {version:'0.3.0',experiment:'disk_safety_4000_v3',labels:sets.values.sum(&:size),human_verified_rows:0,
  independent_review_rows:review.size,excluded_families:excluded,synthetic_facts:'fixture assertions, not real hardware evidence',
  source_sha256:Digest::SHA256.file(File.join(DiskTrial::OUT,'candidates.jsonl')).hexdigest,
  test_status:'Frozen before trial3; disjoint disk mutation recipes; shared policy wording and device names; not human gold',splits:{}}
groups, states, ids = {}, {}, []
sets.each do |split, rows|
  rows.each do |r|
    raise 'ID duplicate' if ids.include?(r['id'])
    ids << r['id']
    raise 'Group leakage' if groups.key?(r['group_id']) && groups[r['group_id']]!=split
    groups[r['group_id']]=split
    key=JSON.generate(r['state'])
    raise 'State leakage' if states.key?(key) && states[key]!=split
    raise 'Duplicate full input inside split' if states.key?(key)
    states[key]=split
  end
  path=File.join(dataset,split+'.jsonl')
  DiskTrial.jsonl(path,rows)
  manifest[:splits][split]={rows:rows.size,positives:rows.count { |r| r.dig('targets','gate','label')=='needs_review' },
    groups:rows.map { |r| r['group_id'] }.uniq.size,sha256:Digest::SHA256.file(path).hexdigest}
end
regression=DiskTrial.rows(File.join(DiskTrial::OLD,'dataset/locked_test_candidate.jsonl'))
policy=JSON.parse(File.read(File.join(DiskTrial::OLD,'trial-002/policy-contrast-inputs.json')))
policy.each { |r| r['group_id']='observed-policy-contrasts'; r['split']='regression' }
DiskTrial.jsonl(File.join(dataset,'regression.jsonl'),regression+policy)
manifest[:regression_sha256]=Digest::SHA256.file(File.join(dataset,'regression.jsonl')).hexdigest
DiskTrial.json(File.join(dataset,'manifest.json'),manifest)
DiskTrial.json(File.join(DiskTrial::OUT,'独立复核与隔离.json'),{reviewed:review.size,disputes:disputes,excluded_families:excluded,human_gold:0})
DiskTrial.json(File.join(DiskTrial::OUT,'数据隔离与平衡审计.json'),{passed:true,train_unique:train.size,train_positives:2000,train_negatives:2000,
  historical_rows:train.count { |r| r['id'].start_with?('CDX10-') },previous_synthetic:train.count { |r| r['id'].start_with?('SYN2-') },
  new_synthetic:train.count { |r| r['id'].start_with?('DSK3-') },new_test_rows:sets['locked_test_candidate'].size,
  deduplicated_seed_rows:deduplicated_seed_rows,conflicting_seed_inputs:conflicting.size,
  family_leakage:false,exact_state_leakage:false,duplicate_inputs:false,historical_commands_executed:false})
puts JSON.generate(train:train.size,test:sets['locked_test_candidate'].size,reviewed:review.size,disputes:disputes.size,excluded_families:excluded)
