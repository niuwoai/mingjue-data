require_relative 'augment'
require 'set'

groups, states, ids, stats = {}, {}, Set.new, {}
SPLITS.each do |split|
  rows = File.readlines(File.join(OUT, 'dataset', split + '.jsonl')).map { |l| JSON.parse(l) }
  rows.each do |row|
    raise 'Duplicate ID' unless ids.add?(row['id'])
    raise 'Group leakage' if groups.key?(row['group_id']) && groups[row['group_id']] != split
    groups[row['group_id']] = split
    key = JSON.generate(row['state'])
    raise 'State leakage' if states.key?(key) && states[key] != split
    states[key] = split
    text = JSON.generate(row['state'])
    raise 'Sensitive token' if text.match?(/sk-[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----\\n[A-Za-z0-9+\/=]{64,}/)
  end
  syn = rows.select { |r| r['id'].start_with?('SYN2-') }
  pairs = syn.group_by { |r| r['state']['command'] }.values.count do |same|
    same.map { |r| r.dig('targets', 'gate', 'label') }.uniq.size == 2
  end
  stats[split] = {rows: rows.size, synthetic_rows: syn.size, same_command_opposite_authorization_pairs: pairs}
  raise 'No counterfactual pairs' unless pairs.positive?
  next if split == 'train'
  old = File.readlines(File.join(SOURCE, split + '.jsonl')).map { |l| JSON.parse(l) }
  raise 'Original evaluation modified' unless old == rows.reject { |r| r['id'].start_with?('SYN2-') }
end
result = {passed: true, historical_commands_executed: false, unique_ids: ids.size, groups: groups.size, splits: stats}
write_json(File.join(OUT, 'augmentation-audit.json'), result)
puts JSON.pretty_generate(result)
