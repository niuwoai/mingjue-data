require 'minitest/autorun'
require 'json'
require 'csv'
require_relative 'shell_dialect_data'

class ShellDialectDataTest < Minitest::Test
  ROOT = ShellDialectData::OUT

  def rows(name)
    File.foreach(File.join(ROOT, 'dataset', "#{name}.jsonl")).map { |line| JSON.parse(line) }
  end

  def test_counts_and_class_balance
    train = rows('train')
    test = rows('locked_test_candidate')
    assert_equal 16_000, train.length
    assert_equal 8_000, ShellDialectData.positives(train)
    assert_equal 1_200, test.length
    assert_equal 600, ShellDialectData.positives(test)
    assert_equal 3_073, rows('regression').length
  end

  def test_no_exact_state_or_group_leakage
    train = rows('train')
    test = rows('locked_test_candidate')
    assert_empty train.map { |row| JSON.generate(row['state']) } & test.map { |row| JSON.generate(row['state']) }
    assert_empty train.map { |row| row['group_id'] }.uniq & test.map { |row| row['group_id'] }.uniq
  end

  def test_safe_write_pairs_change_context_not_command
    train = rows('train').select { |row| row['id'].include?('-safe-000-') }
    pairs = train.group_by { |row| row['group_id'] }
    assert_equal 5, pairs.length
    pairs.each_value do |pair|
      assert_equal 2, pair.length
      assert_equal 1, pair.map { |row| row['state']['command'] }.uniq.length
      assert_equal %w[allow needs_review], pair.map { |row| row.dig('targets', 'gate', 'label') }.sort
      refute_equal pair[0]['state']['visible_user_context_candidates'], pair[1]['state']['visible_user_context_candidates']
    end
  end

  def test_human_review_sheet_is_unlabelled_and_balanced_by_pair
    csv_path = File.join(ROOT, '人工复核表.csv')
    csv = CSV.read(csv_path, headers: true, encoding: 'bom|utf-8')
    assert_equal 200, csv.length
    assert_equal 11, csv.headers.length
    assert csv.all? { |row| row.fields.length == csv.headers.length }
    %w[human_gate human_risk human_authorization evidence annotator].each do |field|
      assert csv.all? { |row| row[field].nil? || row[field].empty? }
    end
  end

  def test_manifest_remains_nonqualified
    manifest = JSON.parse(File.read(File.join(ROOT, 'dataset', 'manifest.json')))
    assert_equal false, manifest['human_gold']
    assert_equal false, manifest['production_qualified']
    assert_equal 0, manifest['human_verified_rows']
  end
end
