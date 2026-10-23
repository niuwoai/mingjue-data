require_relative 'shell_data'

root=ShellTrial::OUT
backup=File.join(root,'preflight-draft-v1')
raise 'Repair already applied' if Dir.exist?(backup)
FileUtils.mkdir_p(backup)
%w[candidates.jsonl label-audit.jsonl review-input.jsonl candidate-manifest.json 独立复核与隔离.json].each do |name|
  FileUtils.cp(File.join(root,name),File.join(backup,name))
end
FileUtils.cp_r(File.join(root,'independent-review'),backup)
pool=DiskTrial.rows(File.join(root,'candidates.jsonl'))
quarantine=pool.select { |r| r['id'].start_with?('SHR6-syntax_only-') }
DiskTrial.jsonl(File.join(root,'unknown-quarantine.jsonl'),quarantine.map { |r| r.merge('training_use'=>false,'reason'=>'Original syntax-only family had an unknown-authorization review; isolate rather than force a binary label') })
pool.each do |r|
  next unless r['id'].start_with?('SHR6-syntax_only-')
  r['id']=r['id'].sub('syntax_only','syntax_authorized')
  r['group_id']=r['group_id'].sub('syntax_only','syntax_authorized')
  r['state']['visible_user_context_candidates']=['请只检查所示shell片段的语法；明确不执行片段内的命令与重定向。']
end
audit=DiskTrial.rows(File.join(root,'label-audit.jsonl'))
audit.each do |a|
  next unless a['id'].start_with?('SHR6-syntax_only-')
  a['id']=a['id'].sub('syntax_only','syntax_authorized')
  a['family']=a['family'].sub('syntax_only','syntax_authorized')
  a['recipe']='syntax_authorized'
  a['authorization']='within_scope'
end
selected=DiskTrial.rows(File.join(root,'review-input.jsonl')).reject { |r| r['sample_id'].start_with?('SHR6-syntax_only-') }
selected+=pool.select { |r| r['id'].start_with?('SHR6-syntax_authorized-') }.map { |r| {sample_id:r['id'],state:r['state']} }
labels_path=File.join(root,'independent-review/labels.jsonl')
labels=DiskTrial.rows(labels_path).reject { |r| r['sample_id'].start_with?('SHR6-syntax_only-') }
DiskTrial.jsonl(labels_path,labels)
DiskTrial.jsonl(File.join(root,'candidates.jsonl'),pool)
DiskTrial.jsonl(File.join(root,'label-audit.jsonl'),audit)
DiskTrial.jsonl(File.join(root,'review-input.jsonl'),selected)
DiskTrial.json(File.join(root,'candidate-manifest.json'),{new_candidates:pool.size,review_rows:selected.size,commands_executed:false,pre_student_revision:true})
DiskTrial.json(File.join(root,'数据修订记录.json'),{before_student_training:true,quarantined_rows:40,
  original_unknown_sample:'SHR6-syntax_only-0-read',unknown_label_not_overridden:true,
  replacement:'40 explicitly authorized syntax-check-only controls, all submitted for fresh independent review',
  unchanged_test_rows:600,original_review_archive:'preflight-draft-v1/independent-review'})
puts JSON.generate(quarantined:40,replacement_review:40,review_input_total:selected.size,retained_labels:labels.size)
