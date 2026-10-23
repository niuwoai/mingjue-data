require_relative 'short_data'

root=ShortTrial::OUT
review=DiskTrial.rows(File.join(root,'independent-review/labels.jsonl'))
selected=DiskTrial.rows(File.join(root,'review-input.jsonl'))
raise 'Review incomplete' unless review.map { |r| r['sample_id'] }.sort==selected.map { |r| r['sample_id'] }.sort
audit=DiskTrial.rows(File.join(root,'label-audit.jsonl')).to_h { |r| [r['id'],r] }
pool=DiskTrial.rows(File.join(root,'candidates.jsonl'))
pool.each do |row|
  a=audit.fetch(row['id'])
  if a['variant']==1
    a['authorization']=row['state']['visible_user_context_candidates'].empty? ? 'unknown' : 'within_scope'
    a['review_reason']='irreversible block-device mutation without verified target; not an accusation of malicious intent'
  end
end
disputes=review.select { |r| (%w[review block].include?(r['decision']) ? 'needs_review' : r['decision'])!=audit.fetch(r['sample_id'])['label'] }
excluded=disputes.map { |r| audit.fetch(r['sample_id'])['family'] }.uniq
pool.reject! { |r| excluded.include?(r['group_id']) }
old=DiskTrial.rows(File.join(ShortTrial::PREVIOUS,'dataset/train.jsonl'))
choose=->(prefix,label,n) do
  result=old.select { |r| r['id'].start_with?(prefix) && r.dig('targets','gate','label')==label }.shuffle(random:Random.new(n+811)).first(n)
  raise 'Insufficient retained corpus' unless result.size==n
  result
end
train=choose.call('CDX10-','needs_review',24)+choose.call('CDX10-','allow',300)+
      choose.call('SYN2-','needs_review',336)+choose.call('SYN2-','allow',160)+
      choose.call('DSK3-','needs_review',200)+choose.call('DSK3-','allow',100)
raise 'Unexpected seed size' unless train.size==1120
%w[allow needs_review].each do |label|
  buckets=pool.select { |r| r['split']=='train' && r.dig('targets','gate','label')==label }.
    group_by { |r| a=audit.fetch(r['id']); [a['recipe'],a['variant']] }.values
  rng=Random.new(label=='allow' ? 445 : 446)
  buckets.each { |b| b.shuffle!(random:rng) }
  pick=[]
  while pick.size<1440
    available=buckets.reject(&:empty?)
    raise 'Insufficient short-context coverage after review' if available.empty?
    available.each { |b| pick<<b.pop if pick.size<1440 }
  end
  train.concat(pick)
end
sets={'train'=>train}
DiskTrial::SPLITS.drop(1).each { |s| sets[s]=pool.select { |r| r['split']==s } }
groups,states,ids={},{},{}
sets.each do |split,rows|
  rows.each do |r|
    raise 'Duplicate ID' if ids[r['id']]
    ids[r['id']]=true
    raise 'Combination family leakage' if groups.key?(r['group_id']) && groups[r['group_id']]!=split
    groups[r['group_id']]=split
    key=JSON.generate(r['state'])
    raise 'Full input duplicate or leakage' if states.key?(key)
    states[key]=split
  end
end
sentinel='mkfs.ext4 /dev/nvme0n1'
raise 'Exact original command must stay regression-only' if train.any? { |r| r['state']['command']==sentinel }
dataset=File.join(root,'dataset')
raise 'Dataset already frozen' if File.exist?(File.join(dataset,'manifest.json'))
FileUtils.mkdir_p(dataset)
manifest={version:'0.4.0',experiment:'short_context_4000_v4',human_verified_rows:0,labels:sets.values.sum(&:size),
  independent_review_rows:review.size,excluded_families:excluded,
  split_protocol:'Held-out command wrapper/task/target combinations; semantic operations and some wording shared; synthetic, not human gold',
  source_sha256:Digest::SHA256.file(File.join(root,'candidates.jsonl')).hexdigest,splits:{}}
sets.each do |split,rows|
  path=File.join(dataset,split+'.jsonl')
  DiskTrial.jsonl(path,rows)
  manifest[:splits][split]={rows:rows.size,positives:rows.count { |r| r.dig('targets','gate','label')=='needs_review' },sha256:Digest::SHA256.file(path).hexdigest}
end
regression=DiskTrial.rows(File.join(ShortTrial::PREVIOUS,'dataset/regression.jsonl'))+
  DiskTrial.rows(File.join(ShortTrial::PREVIOUS,'dataset/locked_test_candidate.jsonl'))
DiskTrial.jsonl(File.join(dataset,'regression.jsonl'),regression)
manifest[:regression_sha256]=Digest::SHA256.file(File.join(dataset,'regression.jsonl')).hexdigest
DiskTrial.json(File.join(dataset,'manifest.json'),manifest)
DiskTrial.jsonl(File.join(root,'normalized-label-audit.jsonl'),audit.values)
DiskTrial.json(File.join(root,'独立复核与隔离.json'),{reviewed:review.size,disputes:disputes,excluded_families:excluded,human_gold:0})
short=train.select { |r| r['id'].start_with?('SHT4-') }
DiskTrial.json(File.join(root,'数据审计.json'),{passed:true,unique_train:4000,normal:2000,needs_review:2000,
  short_train:short.size,short_review:short.count { |r| r.dig('targets','gate','label')=='needs_review' },
  historical_weak:324,previous_synthetic:796,synthetic_facts_are_not_real_telemetry:true,
  new_test:sets['locked_test_candidate'].size,exact_original_command_train:false,unknown_forced_harmful:false,commands_executed:false})
puts JSON.generate(train:train.size,short:short.size,test:sets['locked_test_candidate'].size,disputes:disputes.size,excluded:excluded)
