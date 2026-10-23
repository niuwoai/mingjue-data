require 'csv'
require 'json'
require 'minitest/autorun'
require_relative 'shell_authorization_data'

class ShellAuthorizationDataTest < Minitest::Test
  ROOT = ShellAuthorizationData::OUT

  def rows(name)
    File.foreach(File.join(ROOT, 'dataset', "#{name}.jsonl")).map { |line| JSON.parse(line) }
  end

  def test_frozen_counts_are_balanced
    train = rows('train')
    test = rows('locked_test_candidate')
    assert_equal 24_000, train.size
    assert_equal 12_000, ShellAuthorizationData.positive_count(train)
    assert_equal 1_200, test.size
    assert_equal 600, ShellAuthorizationData.positive_count(test)
  end

  def test_same_command_pairs_differ_by_authorization_context
    added = File.foreach(File.join(ROOT, 'new-train-candidates.jsonl')).map { |line| JSON.parse(line) }
    pairs = added.group_by { |item| item['group_id'] }
    assert_equal 2_000, pairs.size
    pairs.each_value do |pair|
      assert_equal 2, pair.size
      assert_equal 1, pair.map { |item| item.dig('state', 'command') }.uniq.size
      assert_equal %w[allow needs_review], pair.map { |item| item.dig('targets', 'gate', 'label') }.sort
      assert_equal 2, pair.map { |item| JSON.generate(item['state']) }.uniq.size
    end
  end

  def test_test_families_are_group_and_state_disjoint_from_train
    train = rows('train')
    test = rows('locked_test_candidate')
    assert_empty train.map { |row| row['group_id'] }.uniq & test.map { |row| row['group_id'] }.uniq
    assert_empty train.map { |row| JSON.generate(row['state']) } & test.map { |row| JSON.generate(row['state']) }
    assert_empty train.map { |row| row.dig('state', 'command') }.uniq & test.map { |row| row.dig('state', 'command') }.uniq

    pairs = test.group_by { |item| item['group_id'] }
    assert_equal 600, pairs.size
    assert pairs.values.all? { |pair| pair.size == 2 && pair.map { |row| row.dig('state', 'command') }.uniq.one? }
  end

  def test_pending_escalation_is_not_labeled_as_approval
    pair = rows('train').select { |row| row['group_id'].end_with?(':cat_redirect:1') }
    review = pair.find { |row| row.dig('targets', 'gate', 'label') == 'needs_review' }
    allow = pair.find { |row| row.dig('targets', 'gate', 'label') == 'allow' }
    assert_equal 'require_escalated', review.dig('state', 'requested_sandbox_permissions')
    assert_includes review.dig('state', 'approval_justification'), '不是用户'
    assert_nil allow.dig('state', 'requested_sandbox_permissions')
  end

  def test_blind_review_queue_has_no_prefilled_labels
    csv = CSV.read(File.join(ROOT, '人工复核表.csv'), headers: true, encoding: 'bom|utf-8')
    assert_equal 200, csv.size
    assert csv.all? { |row| row['gate_label'].to_s.empty? && row['human_decision'].to_s.empty? }
    manifest = JSON.parse(File.read(File.join(ROOT, 'dataset/manifest.json')))
    assert_equal false, manifest['human_gold']
    assert_equal 0, manifest['human_verified_rows']
  end
end
