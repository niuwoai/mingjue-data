require 'minitest/autorun'
require_relative 'import_shell_literal_test_review'

class ImportShellLiteralTestReviewTest < Minitest::Test
  def setup
    @source = [
      { 'blind_sample_id' => 'SAMPLE-a', 'blind_pair_id' => 'PAIR-x', 'command' => 'puts dangerous text', 'visible_user_context' => 'display' },
      { 'blind_sample_id' => 'SAMPLE-b', 'blind_pair_id' => 'PAIR-x', 'command' => 'run dangerous command', 'visible_user_context' => 'execute' }
    ]
    @annotations = [
      @source[0].merge('human_gate' => 'allow', 'evidence' => 'text only', 'reviewer' => 'r1'),
      @source[1].merge('human_gate' => 'needs_review', 'evidence' => 'exec call', 'reviewer' => 'r1')
    ]
    @mapping = { 'labels' => [
      { 'blind_id' => 'SAMPLE-a', 'source_id' => 'source-a', 'group_id' => 'g-a', 'expected_gate' => 'needs_review' },
      { 'blind_id' => 'SAMPLE-b', 'source_id' => 'source-b', 'group_id' => 'g-b', 'expected_gate' => 'needs_review' }
    ] }
    @frozen_test = [
      { 'id' => 'source-a', 'group_id' => 'g-a', 'state' => {}, 'targets' => { 'gate' => { 'label' => 'needs_review' } } },
      { 'id' => 'source-b', 'group_id' => 'g-b', 'state' => {}, 'targets' => { 'gate' => { 'label' => 'needs_review' } } }
    ]
  end

  def test_uses_human_gate_without_mutating_frozen_test_and_reports_policy_disagreement
    gold, disagreements = ImportShellLiteralTestReview.build_gold_rows(source_rows: @source,
      annotated_rows: @annotations, mapping: @mapping, frozen_test_rows: @frozen_test)
    assert_equal %w[allow needs_review], gold.map { |row| row.dig('targets', 'gate', 'label') }
    assert_equal 1, disagreements.size
    assert_equal 'needs_review', @frozen_test.first.dig('targets', 'gate', 'label')
  end

  def test_rejects_missing_or_duplicate_annotations
    assert_raises(RuntimeError) do
      ImportShellLiteralTestReview.build_gold_rows(source_rows: @source,
        annotated_rows: @annotations.first(1), mapping: @mapping, frozen_test_rows: @frozen_test)
    end
    assert_raises(RuntimeError) do
      ImportShellLiteralTestReview.build_gold_rows(source_rows: @source,
        annotated_rows: @annotations + [@annotations.first], mapping: @mapping, frozen_test_rows: @frozen_test)
    end
  end
end
