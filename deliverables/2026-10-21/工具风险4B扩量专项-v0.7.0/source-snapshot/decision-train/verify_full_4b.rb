require 'json'
require 'digest'

base=ARGV.fetch(0)
run=File.join(base,'trial-005')
read=->(path) { JSON.parse(File.read(path)) }
hashes=read.call(File.join(run,'artifact-sha256.json'))
hashes.each do |name,sha|
  raise "Downloaded artifact mismatch: #{name}" unless Digest::SHA256.file(File.join(run,name)).hexdigest==sha
end
manifest=read.call(File.join(base,'dataset/manifest.json'))
read.call(File.join(run,'data-audit.json')).each do |split,audit|
  raise 'Frozen split differs' unless audit['sha256']==manifest['splits'][split]['sha256']
end
rows=File.readlines(File.join(base,'dataset/train.jsonl')).map { |l| JSON.parse(l) }.to_h { |r| [r['id'],r] }
order=read.call(File.join(run,'training-order.json'))
raise 'Wrong training coverage' unless order.size==4096 && order.uniq.size==4000
raise 'Exposure differs from 2B' unless order==read.call(File.join(base,'baseline-2b/training-order.json'))
order.each_slice(16) do |batch|
  raise 'Unbalanced accumulation' unless batch.count { |id| rows.fetch(id).dig('targets','gate','label')=='needs_review' }==8
end
model=read.call(File.join(run,'model-provenance.json'))
download=read.call(File.join(run,'model-base-download-verification.json'))
raise 'Wrong model identity' unless model['revision']=='1e65a988dacbcf00b84aee7366f9e47563407000' && model['start_from_original_base_not_probe_adapter'] && download['all_verified']
raise 'Base provenance changed' unless model['download_verification_sha256']==Digest::SHA256.file(File.join(run,'model-base-download-verification.json')).hexdigest
raise 'Official metadata mismatch' unless download['official_metadata_sha256']==Digest::SHA256.file(File.join(base,'4B官方元数据.json')).hexdigest
service=read.call(File.join(run,'service-verification.json'))
raise 'Training or inference incomplete' unless service['Result']=='success' && service['ActiveState']=='inactive' && service['qwen_service']=='active' && service['watchdog_timer']=='active' && service['health_http']==200 && service.dig('health_body','status')=='ok'
service['remote_source_sha256'].each do |name,sha|
  raise "Source snapshot differs: #{name}" unless Digest::SHA256.file(File.join(base,'source-snapshot',name)).hexdigest==sha
end
reload_result=read.call(File.join(run,'reload-verification.json'))
raise 'Independent reload failed' unless reload_result['fresh_process'] && reload_result['passed'] && reload_result['rows']==500
pred=read.call(File.join(run,'adapter-locked_test_candidate.json'))
old=read.call(File.join(base,'baseline-2b/adapter-locked_test_candidate.json'))
ids=File.readlines(File.join(base,'dataset/locked_test_candidate.jsonl')).map { |l| JSON.parse(l)['id'] }
raise 'Wrong test population' unless pred.map { |r| r['id'] }==ids && old.map { |r| r['id'] }==ids
transitions=read.call(File.join(run,'paired-test-transitions.json'))
raise 'Paired table wrong' unless transitions.size==500
transitions.each_with_index do |r,i|
  raise 'Paired scores or labels differ' unless r['id']==ids[i] && r['probability_2b']==old[i]['probability'] && r['probability_4b']==pred[i]['probability'] && r['label']==pred[i]['label'] && r['label']==old[i]['label']
end
raise 'Focus cohort differs' unless transitions.count { |r| r['previous_category']=='false_allow' }==5 && transitions.count { |r| r['previous_category']=='false_review' }==21
provenance=read.call(File.join(run,'comparison-provenance.json'))
provenance['previous_2b_files_sha256'].each do |name,sha|
  raise "2B baseline mismatch: #{name}" unless Digest::SHA256.file(File.join(base,'baseline-2b',name)).hexdigest==sha
end
m=read.call(File.join(run,'metrics.json'))
raise 'Wrong budget or revision' unless m['optimizer_steps']==256 && m['threshold']==0.5 && m['base_revision']==model['revision'] && m['unique_rows_seen']==4000
result={passed:true,artifacts:hashes.size,train_unique:4000,draws:4096,balanced_batches:256,
        same_exposure_order_as_2b:true,same_500_test:true,fixed_threshold:0.5,
        original_false_allow_cohort:5,original_false_review_cohort:21,
        adapter_sha256:hashes['adapter/adapter_model.safetensors'],reload_verified:true,inference_restored:true}
File.write(File.join(base,'本地下载与训练核验.json'),JSON.pretty_generate(result)+"\n")
puts JSON.generate(result)
