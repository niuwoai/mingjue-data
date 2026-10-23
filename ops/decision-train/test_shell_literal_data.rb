require 'minitest/autorun'
require 'json'
require 'csv'
require_relative 'shell_literal_data'

class ShellLiteralDataTest < Minitest::Test
  ROOT = ShellLiteralData::OUT

  def rows(name)
    File.foreach(File.join(ROOT, 'dataset', "#{name}.jsonl")).map { |line| JSON.parse(line) }
  end

  def test_frozen_sizes_and_balance
    train = rows('train')
    test = rows('locked_test_candidate')
    assert_equal 20_000, train.size
    assert_equal 10_000, ShellLiteralData.positive_count(train)
    assert_equal 1_200, test.size
    assert_equal 600, ShellLiteralData.positive_count(test)
  end

  def test_unseen_test_families_are_disjoint
    train = rows('train')
    test = rows('locked_test_candidate')
    train_groups = train.map { |item| item['group_id'] }.uniq
    assert_empty train_groups & test.map { |item| item['group_id'] }.uniq
    assert_empty train.map { |item| JSON.generate(item['state']) } & test.map { |item| JSON.generate(item['state']) }
    manifest = JSON.parse(File.read(File.join(ROOT, 'dataset/manifest.json')))
    assert_equal manifest.dig('regression', 'rows'), rows('regression').length
  end

  def test_labels_contrast_literal_display_with_execution
    added = File.foreach(File.join(ROOT, 'new-train-candidates.jsonl')).map { |line| JSON.parse(line) }
    pairs = added.group_by { |item| item['group_id'] }
    assert_equal 2_000, pairs.size
    pairs.each_value do |pair|
      assert_equal %w[allow needs_review], pair.map { |item| item.dig('targets', 'gate', 'label') }.sort
      assert_equal 2, pair.map { |item| item['state']['visible_user_context_candidates'].first }.uniq.size
    end
  end

  def test_human_review_queue_is_blind_and_100_percent_unreviewed
    path = File.join(ROOT, '人工复核表.csv')
    csv = CSV.read(path, headers: true, encoding: 'bom|utf-8')
    assert_equal 200, csv.size
    assert csv.all? { |item| item['gate_label'].to_s.empty? && item['human_decision'].to_s.empty? }
    assert_equal false, JSON.parse(File.read(File.join(ROOT, 'dataset/manifest.json')))['human_gold']
  end
end
