require_relative 'shell_data'

root=ShellTrial::OUT
review=DiskTrial.rows(File.join(root,'independent-review/labels.jsonl'))
selected=DiskTrial.rows(File.join(root,'review-input.jsonl'))
raise 'Review incomplete' unless review.map { |r| r['sample_id'] }.sort==selected.map { |r| r['sample_id'] }.sort
audit=DiskTrial.rows(File.join(root,'label-audit.jsonl')).to_h { |r| [r['id'],r] }
disputes=review.select { |r| (%w[review block].include?(r['decision']) ? 'needs_review' : r['decision'])!=audit.fetch(r['sample_id'])['label'] }
DiskTrial.json(File.join(root,'独立复核与隔离.json'),{reviewed:review.size,disputes:disputes,human_gold:0})
raise 'Disputed families must be isolated before freezing' unless disputes.empty?
pool=DiskTrial.rows(File.join(root,'candidates.jsonl'))
sets={}
DiskTrial::SPLITS.each { |split| sets[split]=pool.select { |r| r['split']==split } }
original=DiskTrial.rows(File.join(ShellTrial::PREVIOUS,'dataset/train.jsonl'))
raise 'Original corpus not 4000' unless original.size==4000
sets['train']=original+sets['train']
raise 'Unexpected frozen train/test size' unless sets['train'].size==6000 && sets['locked_test_candidate'].size==600
ids,states,groups={},{},{}
sets.each do |split,rows|
  rows.each do |row|
    raise 'Duplicate ID' if ids[row['id']]
    ids[row['id']]=true
    key=JSON.generate(row['state'])
    raise 'Exact input duplicate or leakage' if states[key]
    states[key]=split
    raise 'Group crossed split' if groups[row['group_id']] && groups[row['group_id']]!=split
    groups[row['group_id']]=split
  end
  raise 'Unbalanced split' unless rows.count { |r| r.dig('targets','gate','label')=='needs_review' }==rows.size/2
end
previous_test=DiskTrial.rows(File.join(ShellTrial::PREVIOUS,'dataset/locked_test_candidate.jsonl'))
old_commands=previous_test.select { |r| r['state']['command'].include?(' > ') }.map { |r| r['state']['command'] }.uniq
raise 'Known test command literal entered training' if sets['train'].any? { |r| old_commands.include?(r['state']['command']) }
raise 'New frozen test overlaps previous test input' if previous_test.any? { |r| states[JSON.generate(r['state'])] }
dataset=File.join(root,'dataset')
raise 'Already frozen' if File.exist?(File.join(dataset,'manifest.json'))
FileUtils.mkdir_p(dataset)
manifest={version:'0.6.0',experiment:'shell_redirect_6000_v6',human_verified_rows:0,labels:sets.values.sum(&:size),
  independent_review_rows:review.size,split_protocol:'New held-out shell wrapper/task/target combinations; shared writing semantics and some templates; synthetic not human gold',
  original_train_sha256:Digest::SHA256.file(File.join(ShellTrial::PREVIOUS,'dataset/train.jsonl')).hexdigest,
  source_sha256:Digest::SHA256.file(File.join(root,'candidates.jsonl')).hexdigest,splits:{}}
sets.each do |split,rows|
  path=File.join(dataset,split+'.jsonl')
  DiskTrial.jsonl(path,rows)
  manifest[:splits][split]={rows:rows.size,positives:rows.count { |r| r.dig('targets','gate','label')=='needs_review' },sha256:Digest::SHA256.file(path).hexdigest}
end
regression=DiskTrial.rows(File.join(ShellTrial::PREVIOUS,'dataset/regression.jsonl'))+previous_test
DiskTrial.jsonl(File.join(dataset,'regression.jsonl'),regression)
manifest[:regression_sha256]=Digest::SHA256.file(File.join(dataset,'regression.jsonl')).hexdigest
DiskTrial.json(File.join(dataset,'manifest.json'),manifest)
DiskTrial.json(File.join(root,'数据审计.json'),{passed:true,train_unique:6000,new_shell_rows:2000,normal:3000,needs_review:3000,
  original_4000_retained:true,new_test:600,new_test_positive:300,reviewed_representatives:review.size,
  historical_weak:324,synthetic:5676,human_gold:0,commands_executed:false,known_15_remain_regression_only:true})
puts JSON.generate(train:6000,new_test:600,review:review.size,human_gold:0)
