require 'minitest/autorun'
require 'csv'
require 'json'
require_relative 'prepare_shell_literal_test_review'

class PrepareShellLiteralTestReviewTest < Minitest::Test
  def test_blind_review_queue_is_a_paired_subset_without_visible_labels
    directory = File.join(ShellLiteralTestReview::OUT)
    csv = CSV.read(File.join(directory, '独立测试盲审.csv'), headers: true, encoding: 'bom|utf-8')
    mapping = JSON.parse(File.read(File.join(directory, '盲审映射与冻结标签.json')))
    assert_equal 200, csv.size
    assert_equal 100, mapping['sampled_pairs']
    assert_equal 200, mapping['labels'].size
    assert csv.all? { |row| row['human_gate'].to_s.empty? && row['evidence'].to_s.empty? }
    assert_equal 100, csv.map { |row| row['blind_pair_id'] }.uniq.size
    assert csv.all? { |row| row['blind_sample_id'].start_with?('SAMPLE-') }
  end
end
