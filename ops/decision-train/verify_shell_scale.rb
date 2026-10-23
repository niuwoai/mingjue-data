require 'json'
require 'digest'

root = ARGV.fetch(0)
read = ->(path) { JSON.parse(File.read(File.join(root, path))) }
manifest = read.call('dataset/manifest.json')
manifest.fetch('splits').each do |split, info|
  path = File.join(root, 'dataset', split + '.jsonl')
  raise "Frozen split changed: #{split}" unless Digest::SHA256.file(path).hexdigest == info.fetch('sha256')
  rows = File.readlines(path).map { |line| JSON.parse(line) }
  raise "Split count changed: #{split}" unless rows.size == info.fetch('rows')
  raise "Split label count changed: #{split}" unless rows.count { |row| row.dig('targets', 'gate', 'label') == 'needs_review' } == info.fetch('positives')
end
raise 'Wrong frozen experiment' unless manifest['experiment'] == 'shell_redirect_10000_v7' && manifest['human_verified_rows'].zero?

run = 'trial-007'
hashes = read.call("#{run}/artifact-sha256.json")
hashes.each do |path, expected|
  raise "Downloaded run artifact differs: #{path}" unless Digest::SHA256.file(File.join(root, run, path)).hexdigest == expected
end
audit = read.call("#{run}/data-audit.json")
raise 'Training/test tokenization lost rows' unless audit['train']['used'] == 10_000 && audit['train']['source_rows'] == 10_000 &&
  audit['locked_test_candidate']['used'] == 1_200 && audit['locked_test_candidate']['source_rows'] == 1_200
raise 'Tokenization excluded rows' unless audit.values.all? { |split| split['excluded'].empty? }

train = File.readlines(File.join(root, 'dataset/train.jsonl')).map { |line| JSON.parse(line) }.to_h { |row| [row['id'], row] }
order = read.call("#{run}/training-order.json")
raise 'Training did not expose every row once' unless order.size == 10_000 && order.uniq.size == 10_000
raise 'Unique positive training coverage differs' unless order.uniq.count { |id| train.fetch(id).dig('targets', 'gate', 'label') == 'needs_review' } == 5_000
order.each_slice(16) do |batch|
  raise 'Unbalanced gradient accumulation batch' unless batch.size == 16 && batch.count { |id| train.fetch(id).dig('targets', 'gate', 'label') == 'needs_review' } == 8
end

metrics = read.call("#{run}/metrics.json")
raise 'Unexpected optimizer steps or version' unless metrics['optimizer_steps'] == 625 && metrics['version'] == '0.9.0' && metrics['threshold'] == 0.5
raise 'Unexpected base revision' unless metrics['base_revision'] == '1e65a988dacbcf00b84aee7366f9e47563407000'
reload = read.call("#{run}/reload-verification.json")
raise 'Independent fresh-process reload failed' unless reload['fresh_process'] && reload['passed'] && reload['rows'] == 1_200

service = read.call("#{run}/service-verification.json")
raise 'Training or service restoration failed' unless service['ActiveState'] == 'inactive' && service['Result'] == 'success' &&
  service['qwen_service'] == 'active' && service['watchdog_timer'] == 'active' && service['health_http'] == 200 &&
  service.dig('health_body', 'status') == 'ok'

comparison = read.call("#{run}/shell-scale-comparison.json")
test_rows = File.readlines(File.join(root, 'dataset/locked_test_candidate.jsonl')).map { |line| JSON.parse(line) }
%w[base-scaled-test.json previous4b-scaled-test.json current4b-scaled-test.json].each do |name|
  predictions = read.call("#{run}/#{name}")
  raise "Test prediction IDs differ: #{name}" unless predictions.map { |row| row['id'] } == test_rows.map { |row| row['id'] }
  raise "Test prediction labels differ: #{name}" unless predictions.map { |row| row['label'] } == test_rows.map { |row| row.dig('targets', 'gate', 'label') == 'needs_review' ? 1 : 0 }
end
raise 'Comparison omitted model results' unless comparison.dig('new_test', 'current4b', 'all', 'rows') == 1_200 &&
  comparison.dig('new_test', 'previous4b', 'all', 'rows') == 1_200
acceptance = read.call('验收结果.json')
raise 'Production qualification must remain false' unless acceptance['production_qualified'] == false && acceptance['human_gold'] == 0

result = { passed: true, train_rows: 10_000, train_positive: 5_000, unique_exposures: 10_000,
  balanced_batches: 625, test_rows: 1_200, test_positive: 600, regression_rows: manifest.dig('regression', 'rows'),
  model_revision: metrics['base_revision'], adapter_sha256: hashes.fetch('adapter/adapter_model.safetensors'),
  reload_max_score_difference: reload['max_probability_difference'], service_restored: true,
  experiment_targets_passed: acceptance['experiment_targets_passed'], production_qualified: false }
File.write(File.join(root, '本地训练核验.json'), JSON.pretty_generate(result) + "\n")
puts JSON.generate(result)
