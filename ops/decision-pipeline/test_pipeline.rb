# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'prepare'
require_relative 'labels'
require_relative 'export'
require 'tmpdir'

class PipelineTest < Minitest::Test
  def test_credentials_redacted_but_scope_preserved
    sanitizer = DecisionData::Sanitizer.new
    text = sanitizer.clean('API_KEY="sk-proj-abcdefghijklmnopqrstuvwxyz" rm -rf /tmp/cache')
    refute_includes text, 'abcdefghijklmnopqrstuvwxyz'
    assert_includes text, 'rm -rf /tmp/cache'
  end

  def test_password_and_private_key_redacted
    sanitizer = DecisionData::Sanitizer.new
    text = sanitizer.clean("password=testing123 -----BEGIN PRIVATE KEY-----\nTEST\n-----END PRIVATE KEY-----")
    refute_includes text, 'testing123'
    refute_includes text, 'BEGIN PRIVATE KEY'
  end

  def test_group_cannot_cross_splits
    rows = [{ sample_id: '1', group_id: 'a', split: 'train', pilot_related_group: false },
            { sample_id: '2', group_id: 'a', split: 'development', pilot_related_group: false }]
    assert_raises(RuntimeError) { DecisionData.validate_groups(rows) }
  end

  def test_pilot_related_group_cannot_enter_test
    rows = [{ sample_id: '1', group_id: 'a', split: 'locked_test_candidate', pilot_related_group: true }]
    assert_raises(RuntimeError) { DecisionData.validate_groups(rows) }
  end

  def fixture
    [{ 'sample_id' => 'x', 'state' => { 'command' => 'git status' } }]
  end

  def label
    { 'sample_id' => 'x', 'risk' => 'low', 'authorization' => 'within_scope',
      'decision' => 'allow', 'reason_codes' => ['read_only'], 'evidence' => ['git status'],
      'missing_information' => '', 'confidence' => 0.9 }
  end

  def test_hallucinated_evidence_rejected
    assert_raises(RuntimeError) do
      DecisionData::Labels.validate_batch([label.merge('evidence' => ['approved deployment'])], fixture)
    end
  end

  def test_duplicate_missing_or_wrong_ids_rejected
    assert_raises(RuntimeError) { DecisionData::Labels.validate_batch([label, label], fixture) }
    assert_raises(RuntimeError) { DecisionData::Labels.validate_batch([], fixture) }
    assert_raises(RuntimeError) { DecisionData::Labels.validate_batch([label.merge('sample_id' => 'other')], fixture) }
  end

  def test_valid_label_keeps_all_dimensions
    assert DecisionData::Labels.validate_batch([label], fixture)
    assert_raises(RuntimeError) do
      DecisionData::Labels.validate_batch([label.merge('authorization' => 'probably')], fixture)
    end
  end

  def test_only_verbatim_long_quote_can_be_trimmed
    input = [{ 'sample_id' => 'x', 'state' => { 'command' => 'x' * 160 } }]
    value = label.merge('evidence' => ['x' * 160])
    DecisionData::Labels.validate_batch([value], input)
    assert_equal 100, value['evidence'].first.size
    assert_equal 'long_verbatim_quote_trimmed_to_100_characters', value['evidence_normalization']
  end

  def test_independent_review_must_agree_on_all_three_axes
    assert_equal 'teacher_only', DecisionData::Export.review_status(label, nil)
    assert_equal 'ai_agreement', DecisionData::Export.review_status(label, label.dup)
    assert_equal 'disputed', DecisionData::Export.review_status(label, label.merge('risk' => 'high'))
    assert_equal 'disputed', DecisionData::Export.review_status(label, label.merge('decision' => 'review'))
    assert_equal 'disputed', DecisionData::Export.review_status(label, label.merge('repeat_disagreement' => true))
  end

  def test_canonical_fingerprint_does_not_depend_on_json_key_order
    left = { 'command' => 'git status', 'context' => { 'b' => 2, 'a' => 1 } }
    right = { 'context' => { 'a' => 1, 'b' => 2 }, 'command' => 'git status' }
    assert_equal JSON.generate(DecisionData::Export.canonical(left)), JSON.generate(DecisionData::Export.canonical(right))
  end

  def test_export_rejects_lineage_and_pilot_leakage
    rows = [{ 'sample_id' => '1', 'group_id' => 'a', 'split' => 'train', 'pilot_related_group' => true },
            { 'sample_id' => '2', 'group_id' => 'a', 'split' => 'locked_test_candidate', 'pilot_related_group' => false }]
    assert_raises(RuntimeError) { DecisionData::Export.validate(rows) }
    assert_raises(RuntimeError) { DecisionData::Export.validate([rows.first.merge('split' => 'locked_test_candidate')]) }
  end

  def test_export_excludes_unknown_and_disputes_without_leaking_labels
    Dir.mktmpdir do |dir|
      rows = (1..4).map do |n|
        { 'sample_id' => n.to_s, 'group_id' => n.to_s, 'split' => 'train',
          'pilot_related_group' => false, 'state' => { 'command' => "inspect-#{n}" } }
      end
      primary = (1..4).map { |n| label.merge('sample_id' => n.to_s) }
      primary[1]['decision'] = 'unknown'
      primary[2]['decision'] = 'review'
      review = [primary[2].merge('decision' => 'allow')]
      %w[input labels review].zip([rows, primary, review]).each do |name, values|
        DecisionData::Export.write_rows(File.join(dir,name), values)
      end
      capture_io do
        DecisionData::Export.build(input: File.join(dir,'input'), labels: File.join(dir,'labels'),
                                  review: File.join(dir,'review'), output: File.join(dir,'out'))
      end
      exported = DecisionData::Export.load_rows(File.join(dir,'out/train.jsonl'))
      assert_equal %w[1 4], exported.map { |r| r['id'] }
      assert_equal({ 'command' => 'inspect-1' }, exported.first['state'])
      refute exported.first['state'].key?('teacher')
      report = JSON.parse(File.read(File.join(dir,'out/manifest.json')))
      assert_equal 0, report['human_verified_rows']
      assert_equal 1, report['exclusions']['ai_disagreement']
      assert_equal 1, report['exclusions']['insufficient_historical_evidence']
    end
  end
end
