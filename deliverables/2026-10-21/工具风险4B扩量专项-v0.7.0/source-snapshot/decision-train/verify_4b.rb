require 'json'
require 'digest'

base=ARGV.fetch(0)
run=File.join(base,'probe-4b-001')
read=->(name) { JSON.parse(File.read(File.join(run,name))) }
hashes=read.call('artifact-sha256.json')
hashes.each do |name,expected|
  raise "4B artifact mismatch: #{name}" unless Digest::SHA256.file(File.join(run,name)).hexdigest==expected
end
download=read.call('download-verification.json')
metadata=JSON.parse(File.read(File.join(base,'4B官方元数据.json')))
raise 'Model identity mismatch' unless download['repo']==metadata['id'] && download['revision']==metadata['sha']
raise 'Metadata provenance mismatch' unless download['official_metadata_sha256']==Digest::SHA256.file(File.join(base,'4B官方元数据.json')).hexdigest
raise 'Unverified remote files' unless download['all_verified'] && download['files'].size==15 && download['files'].all? { |f| f['verified'] && f['cached'] }
native=read.call('probe-metrics.json')
raise 'Probe did not update' unless native['completed'] && native['optimizer_steps']==2 && native['forward_backward_calls']==8 && native['updated_adapter_tensors']>0
raise 'Wrong precision or adaptation' unless native['dtype']=='bfloat16' && native['lora_rank']==8 && native['microbatch']==1
raise 'Missing length stress or finite loss' unless native['tested_token_lengths'].include?(1536) && native['trace'].size==8 && native['trace'].all? { |r| r['loss'].finite? }
raise 'Fresh reload failed' unless read.call('probe-reload.json')['passed'] && read.call('probe-reload.json')['fresh_process']
service=read.call('service-verification.json')
%w[rsi-model-4b-download.service rsi-tool-gate-4b-probe.service].each do |unit|
  raise "Job incomplete: #{unit}" unless service[unit]['Result']=='success' && service[unit]['ActiveState']=='inactive'
end
raise 'Inference/watchdog restore failed' unless service['qwen_service']=='active' && service['watchdog_timer']=='active' && service['health_http']==200 && service.dig('health_body','status')=='ok'
manifest=JSON.parse(File.read(File.join(base,'dataset/manifest.json')))
read.call('data-audit.json').each do |split,audit|
  raise 'Probe dataset not frozen dataset' unless audit['sha256']==manifest['splits'][split]['sha256']
end
result={passed:true,downloaded_probe_artifacts:hashes.size,official_revision:download['revision'],
        remote_model_files_verified:download['files'].size,bf16_lora_training_steps:2,
        max_tested_tokens:1536,peak_reserved_gib:native['peak_reserved_bytes']/1024.0**3,
        adapter_sha256:hashes['adapter/adapter_model.safetensors'],fresh_reload_verified:true,
        original_inference_and_watchdog_restored:true,full_four_b_training:false,quality_acceptance:false}
File.write(File.join(base,'4B本地核验.json'),JSON.pretty_generate(result)+"\n")
puts JSON.generate(result)
