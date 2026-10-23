require 'json'
require 'digest'

base = ARGV.fetch(0)
run = File.join(base, 'trial-003')
read = ->(path) { JSON.parse(File.read(path)) }
hashes = read.call(File.join(run, 'artifact-sha256.json'))
hashes.each do |name, expected|
  path = File.join(run, name)
  raise "Downloaded artifact missing or mismatched: #{name}" unless File.file?(path) && Digest::SHA256.file(path).hexdigest == expected
end
manifest = read.call(File.join(base, 'dataset/manifest.json'))
audit = read.call(File.join(run, 'data-audit.json'))
audit.each { |split, info| raise 'Remote dataset mismatch' unless info['sha256'] == manifest['splits'][split]['sha256'] }
rows = File.readlines(File.join(base, 'dataset/train.jsonl')).map { |l| JSON.parse(l) }.to_h { |r| [r['id'], r] }
order = read.call(File.join(run, 'training-order.json'))
raise 'Draw count' unless order.size == 4096
raise 'Unique training coverage is not 4000' unless order.uniq.size == 4000
raise 'Unique positive coverage is not 2000' unless order.uniq.count { |id| rows.fetch(id).dig('targets','gate','label') == 'needs_review' } == 2000
order.each_slice(16) do |batch|
  raise 'Unbalanced batch or non-training ID' unless batch.count { |id| rows.fetch(id).dig('targets','gate','label') == 'needs_review' } == 8
end
service = read.call(File.join(run, 'service-verification.json'))
raise 'Incomplete training or restore' unless service['Result'] == 'success' && service['qwen_service'] == 'active' && service['health_http'] == 200 && service.dig('health_body','status') == 'ok'
service['remote_source_sha256'].each do |name, expected|
  raise "Remote code differs from snapshot: #{name}" unless Digest::SHA256.file(File.join(base, 'source-snapshot', name)).hexdigest == expected
end
reload_result = read.call(File.join(run, 'reload-verification.json'))
raise 'Fresh reload failed' unless reload_result['passed']
diagnostic = read.call(File.join(run, 'diagnostic-service-verification.json'))
raise 'Post-result diagnostic did not finish' unless diagnostic['Result'] == 'success' && diagnostic['ActiveState'] == 'inactive'
result = {passed: true, downloaded_artifacts: hashes.size, draws: order.size, unique_ids: order.uniq.size,
          balanced_batches: order.size/16, every_batch_normal: 8, every_batch_review: 8,
          adapter_sha256: hashes['adapter/adapter_model.safetensors'], service_restored: true,
          source_snapshot_matches_remote: true, dataset_hashes_match: true, reload_verified: true}
File.write(File.join(base, '本地下载与训练核验.json'), JSON.pretty_generate(result)+"\n")
puts JSON.generate(result)
