require 'json'
require 'digest'

base = ARGV.fetch(0)
run = File.join(base, 'trial-004')
read = ->(path) { JSON.parse(File.read(path)) }
hashes = read.call(File.join(run, 'artifact-sha256.json'))
hashes.each do |name, expected|
  path = File.join(run, name)
  raise "Downloaded artifact mismatch: #{name}" unless File.file?(path) && Digest::SHA256.file(path).hexdigest == expected
end
manifest = read.call(File.join(base, 'dataset/manifest.json'))
audit = read.call(File.join(run, 'data-audit.json'))
audit.each { |split, info| raise 'Remote dataset mismatch' unless info['sha256'] == manifest['splits'][split]['sha256'] }
rows = File.readlines(File.join(base, 'dataset/train.jsonl')).map { |l| JSON.parse(l) }.to_h { |r| [r['id'], r] }
order = read.call(File.join(run, 'training-order.json'))
raise 'Draw count' unless order.size == 4096
raise 'Unique training coverage' unless order.uniq.size == 4000
raise 'Positive coverage' unless order.uniq.count { |id| rows.fetch(id).dig('targets','gate','label') == 'needs_review' } == 2000
order.each_slice(16) do |batch|
  raise 'Unbalanced batch or non-training ID' unless batch.count { |id| rows.fetch(id).dig('targets','gate','label') == 'needs_review' } == 8
end
service = read.call(File.join(run, 'service-verification.json'))
raise 'Incomplete training or restore' unless service['Result'] == 'success' && service['qwen_service'] == 'active' && service['health_http'] == 200 && service.dig('health_body','status') == 'ok'
service['remote_source_sha256'].each do |name, expected|
  raise "Remote source mismatch: #{name}" unless Digest::SHA256.file(File.join(base, 'source-snapshot', name)).hexdigest == expected
end
raise 'Fresh reload failed' unless read.call(File.join(run, 'reload-verification.json'))['passed']
comparison = read.call(File.join(run, 'short-comparison.json'))
raise 'Missing common test comparison' unless comparison['new_short_test'].keys.sort == %w[base trial3 trial4]
predictions = read.call(File.join(run, 'trial4-new-test.json'))
expected_ids = File.readlines(File.join(base, 'dataset/locked_test_candidate.jsonl')).map { |l| JSON.parse(l)['id'] }
raise 'Test predictions missing' unless predictions.map { |r| r['id'] }.sort == expected_ids.sort
result = {passed: true, downloaded_artifacts: hashes.size, draws: order.size, unique_ids: order.uniq.size,
          balanced_batches: order.size/16, every_batch_normal: 8, every_batch_review: 8,
          adapter_sha256: hashes['adapter/adapter_model.safetensors'], service_restored: true,
          source_snapshot_matches_remote: true, dataset_hashes_match: true, reload_verified: true,
          new_test_rows_verified: predictions.size}
File.write(File.join(base, '本地下载与训练核验.json'), JSON.pretty_generate(result)+"\n")
puts JSON.generate(result)
