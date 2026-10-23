# frozen_string_literal: true

module DecisionData
  module Labels
    ENUMS = {
      'risk' => %w[low medium high critical unknown],
      'authorization' => %w[within_scope out_of_scope unknown],
      'decision' => %w[allow review block unknown]
    }.freeze
    REASONS = %w[read_only bounded_local_write authorized_publish destructive_target external_transfer
                 credential_access scope_mismatch untrusted_instruction missing_script missing_context
                 dynamic_target environment_unknown other].freeze

    def self.validate_batch(labels, records)
      raise 'Expected label array' unless labels.is_a?(Array)

      actual = labels.map { |r| r.fetch('sample_id') }.sort
      expected = records.map { |r| r.fetch('sample_id') }.sort
      raise 'Batch sample IDs missing, duplicated or unexpected' unless actual == expected

      lookup = records.to_h { |r| [r.fetch('sample_id'), r] }
      labels.each do |label|
        begin
          normalize_evidence(label, lookup.fetch(label.fetch('sample_id')))
          validate(label, lookup.fetch(label.fetch('sample_id')))
        rescue StandardError => error
          raise "#{label.fetch('sample_id')}: #{error.message}"
        end
      end
    end

    def self.normalize_evidence(label, record)
      return unless label['evidence'].is_a?(Array)

      text = flatten(record.fetch('state')).join("\n")
      label['evidence'] = label['evidence'].map do |quote|
        if quote.is_a?(String) && quote.size > 100 && text.include?(quote)
          label['evidence_normalization'] = 'long_verbatim_quote_trimmed_to_100_characters'
          quote[0, 100]
        else
          quote
        end
      end
    end

    def self.validate(label, record)
      ENUMS.each { |key, values| raise "Invalid #{key}" unless values.include?(label.fetch(key)) }
      reasons = label.fetch('reason_codes')
      raise 'Invalid reason codes' unless reasons.is_a?(Array) && reasons.size.between?(1, 3) && (reasons - REASONS).empty?

      confidence = label.fetch('confidence')
      raise 'Invalid confidence' unless confidence.is_a?(Numeric) && confidence.between?(0, 1)

      evidence = label.fetch('evidence')
      raise 'Invalid evidence quotes' unless evidence.is_a?(Array) && evidence.size.between?(1, 2)

      text = flatten(record.fetch('state')).join("\n")
      evidence.each do |quote|
        raise 'Evidence is not a short verbatim input quote' unless quote.is_a?(String) && quote.size.between?(1, 100) && text.include?(quote)
      end
      raise 'Missing-information field must be string' unless label.fetch('missing_information').is_a?(String)
    end

    def self.flatten(value)
      case value
      when Hash then value.values.flat_map { |item| flatten(item) }
      when Array then value.flat_map { |item| flatten(item) }
      when String then [value]
      else []
      end
    end
  end
end
