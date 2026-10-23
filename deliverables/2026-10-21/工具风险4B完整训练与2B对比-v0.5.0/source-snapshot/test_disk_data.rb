require 'minitest/autorun'
require_relative 'disk_data'

class DiskDataTest < Minitest::Test
  def setup
    @dir=File.join(DiskTrial::OUT,'dataset')
    @sets=DiskTrial::SPLITS.to_h { |s| [s,DiskTrial.rows(File.join(@dir,s+'.jsonl'))] }
  end

  def test_unique_balanced_four_thousand
    rows=@sets['train']
    assert_equal 4000,rows.size
    assert_equal 2000,rows.count { |r| r.dig('targets','gate','label')=='needs_review' }
    assert_equal 4000,rows.map { |r| JSON.generate(r['state']) }.uniq.size
  end

  def test_no_group_or_exact_input_leakage
    groups,states={},{}
    @sets.each do |split,rows|
      rows.each do |r|
        assert_equal split,groups.fetch(r['group_id'],split)
        groups[r['group_id']]=split
        key=JSON.generate(r['state'])
        refute states.key?(key)
        states[key]=split
      end
    end
  end

  def test_counterfactual_changes_only_user_authorization
    cases=DiskTrial.rows(File.join(DiskTrial::OUT,'candidates.jsonl')).select { |r| r['id'].start_with?('DSK3-format_btrfs-0-') }
    [2,4].each do |variant|
      allowed=cases.find { |r| r['id'].end_with?("-#{variant}") }
      pending=cases.find { |r| r['id'].end_with?("-#{variant+1}") }
      assert_equal 'allow',allowed.dig('targets','gate','label')
      assert_equal 'needs_review',pending.dig('targets','gate','label')
      assert_equal allowed['state'].reject { |k,_| k=='visible_user_context_candidates' },pending['state'].reject { |k,_| k=='visible_user_context_candidates' }
    end
  end

  def test_live_root_disk_is_not_auto_allowed_by_approval
    [0,1].each { |v| assert_equal 'needs_review',DiskTrial.scenario(0,v).last }
    [2,4].each { |v| assert_equal 'allow',DiskTrial.scenario(0,v).last }
  end

  def test_new_disk_mutation_recipes_are_held_out
    test=@sets['locked_test_candidate'].map { |r| r['group_id'] }.uniq
    train=@sets['train'].map { |r| r['group_id'] }.uniq
    assert_empty test & train
    assert_equal 400,@sets['locked_test_candidate'].size
  end
end
