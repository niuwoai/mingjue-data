require 'json'
require 'digest'

base=ARGV.fetch(0)
run=File.join(base,'trial-006')
read=->(path) { JSON.parse(File.read(path)) }
hashes=read.call(File.join(run,'artifact-sha256.json'))
hashes.each do |name,expected|
  raise "Downloaded artifact mismatch: #{name}" unless Digest::SHA256.file(File.join(run,name)).hexdigest==expected
end
manifest=read.call(File.join(base,'dataset/manifest.json'))
audit=read.call(File.join(run,'data-audit.json'))
audit.each { |split,info| raise 'Frozen split differs' unless info['sha256']==manifest['splits'][split]['sha256'] }
raise 'Overlength training/test exclusion' unless audit['train']['used']==6000 && audit['locked_test_candidate']['used']==600
train_lines=File.readlines(File.join(base,'dataset/train.jsonl'))
raise 'Original 4000 altered' unless Digest::SHA256.hexdigest(train_lines.first(4000).join)==manifest['original_train_sha256']
train=train_lines.map { |line| JSON.parse(line) }.to_h { |r| [r['id'],r] }
order=read.call(File.join(run,'training-order.json'))
raise 'Training budget or coverage' unless order.size==6016 && order.uniq.size==6000
raise 'Positive coverage' unless order.uniq.count { |id| train.fetch(id).dig('targets','gate','label')=='needs_review' }==3000
order.each_slice(16) do |batch|
  raise 'Unbalanced batch' unless batch.count { |id| train.fetch(id).dig('targets','gate','label')=='needs_review' }==8
end
service=read.call(File.join(run,'service-verification.json'))
raise 'Job or restoration incomplete' unless service['ActiveState']=='inactive' && service['Result']=='success' && service['qwen_service']=='active' && service['watchdog_timer']=='active' && service['health_http']==200 && service.dig('health_body','status')=='ok'
raise 'Post-result diagnostic incomplete' unless service.dig('post_result_diagnostic','Result')=='success' && service.dig('post_result_diagnostic','ActiveState')=='inactive'
service['remote_source_sha256'].each do |name,sha|
  raise "Source snapshot mismatch: #{name}" unless Digest::SHA256.file(File.join(base,'source-snapshot',name)).hexdigest==sha
end
model=read.call(File.join(run,'model-provenance.json'))
download=read.call(File.join(run,'model-base-download-verification.json'))
raise 'Wrong base identity' unless model['revision']=='1e65a988dacbcf00b84aee7366f9e47563407000' && model['start_from_original_base_not_probe_adapter'] && download['all_verified']
raise 'Base provenance mismatch' unless model['download_verification_sha256']==Digest::SHA256.file(File.join(run,'model-base-download-verification.json')).hexdigest
raise 'Official metadata mismatch' unless download['official_metadata_sha256']==Digest::SHA256.file(File.join(base,'4B官方元数据.json')).hexdigest
reload_result=read.call(File.join(run,'reload-verification.json'))
raise 'Independent reload failed' unless reload_result['passed'] && reload_result['fresh_process'] && reload_result['rows']==600
test=File.readlines(File.join(base,'dataset/locked_test_candidate.jsonl')).map { |line| JSON.parse(line) }
ids=test.map { |r| r['id'] }
%w[current-new-test.json previous4b-new-test.json base-locked_test_candidate.json].each do |name|
  pred=read.call(File.join(run,name))
  raise 'New comparison population changed' unless pred.map { |r| r['id'] }==ids && pred.map { |r| r['label'] }==test.map { |r| r.dig('targets','gate','label')=='needs_review' ? 1:0 }
end
old15=File.readlines(File.join(base,'冻结旧15条漏放.jsonl')).map { |line| JSON.parse(line) }.to_h { |r| [r['id'],r] }
followup=read.call(File.join(run,'old15-followup.json'))
raise 'Old15 cohort changed' unless followup.map { |r| r['id'] }.sort==old15.keys.sort
followup.each { |r| raise 'Old15 source score changed' unless r['previous_probability']==old15.fetch(r['id'])['probability_4b'] }
raise 'Old26 cohort missing' unless read.call(File.join(run,'old26-followup.json')).size==26
m=read.call(File.join(run,'metrics.json'))
raise 'Wrong training settings' unless m['optimizer_steps']==376 && m['threshold']==0.5 && m['version']=='0.8.0' && m['base_revision']==model['revision']
result={passed:true,downloaded_artifacts:hashes.size,train_unique:6000,positive_unique:3000,draws:6016,
        balanced_batches:376,original_4000_unchanged:true,new_test_rows:600,old15_verified:true,old26_present:true,
        fixed_threshold:0.5,independent_reload:true,source_and_model_provenance_verified:true,
        adapter_sha256:hashes['adapter/adapter_model.safetensors'],original_inference_restored:true}
File.write(File.join(base,'本地下载与训练核验.json'),JSON.pretty_generate(result)+"\n")
puts JSON.generate(result)
