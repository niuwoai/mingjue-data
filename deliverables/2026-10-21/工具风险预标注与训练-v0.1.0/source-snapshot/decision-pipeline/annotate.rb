#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'optparse'
require 'thread'
require 'time'
require_relative 'client'
require_relative 'labels'

module DecisionData
  class AnnotationRun
    def initialize(options)
      @options = options
      @rubric = File.read(File.join(__dir__, 'rubric.md'))
      @mutex = Mutex.new
      @failures = []
      @batches_done = 0
    end

    def run
      FileUtils.mkdir_p(@options[:output], mode: 0o700)
      records = File.foreach(@options[:input]).map { |line| JSON.parse(line) }
      records = records.select { |row| %w[train development].include?(row['split']) } if @options[:development_only]
      records = records.shuffle(random: Random.new(20_261_021)).first(@options[:limit]) if @options[:limit]
      check_manifest
      finished = existing_ids
      pending = records.reject { |row| finished.include?(row.fetch('sample_id')) }
      batches = Queue.new
      pending.each_slice(@options[:batch_size]) { |batch| batches << batch }
      threads = Array.new(@options[:workers]) { Thread.new { worker(batches) } }
      threads.each(&:join)
      puts JSON.generate(completed: existing_ids.size, selected: records.size, failed_batches: @failures.size)
      raise 'Some annotation batches failed; partial progress preserved' unless @failures.empty?
    end

    private

    def check_manifest
      manifest = {
        'input_sha256' => Digest::SHA256.file(@options[:input]).hexdigest,
        'rubric_sha256' => Digest::SHA256.hexdigest(@rubric), 'model' => @options[:model],
        'label_source' => 'teacher_pseudo_label', 'human_verified' => false
      }
      path = File.join(@options[:output], 'manifest.json')
      raise 'Existing run manifest mismatch' if File.exist?(path) && JSON.parse(File.read(path)) != manifest

      File.write(path, JSON.pretty_generate(manifest) + "\n", mode: 'w', perm: 0o600)
    end

    def existing_ids
      path = File.join(@options[:output], 'labels.jsonl')
      return [] unless File.exist?(path)

      File.foreach(path).map { |line| JSON.parse(line).fetch('sample_id') }
    end

    def worker(queue)
      client = ModelClient.new(model: @options[:model])
      loop do
        batch = queue.pop(true)
        annotate_batch(client, batch)
      rescue ThreadError
        break
      end
    end

    def annotate_batch(client, batch)
      records = batch.map { |row| row.slice('sample_id', 'state') }
      attempts = 0
      begin
        attempts += 1
        response = client.completion(@rubric, records)
        persist_raw(batch, response, attempts)
        Labels.validate_batch(response.fetch(:labels), records)
        persist(batch, response)
      rescue StandardError => error
        if attempts < 3
          sleep(attempts * 2)
          retry
        end
        record_failure(batch, error)
      end
    end

    def persist_raw(batch, response, attempt)
      @mutex.synchronize do
        File.open(File.join(@options[:output], 'raw-responses.jsonl'), 'a', 0o600) do |file|
          file.puts(JSON.generate(sample_ids: batch.map { |row| row['sample_id'] }, attempt: attempt,
                                  requested_model: @options[:model], response: response))
        end
      end
    end

    def persist(batch, response)
      @mutex.synchronize do
        timestamp = Time.now.utc.iso8601
        labels = response.fetch(:labels).map do |label|
          label.merge('teacher_requested' => @options[:model], 'teacher_resolved' => response[:model],
                      'label_source' => 'teacher_pseudo_label', 'human_verified' => false,
                      'annotated_at' => timestamp, 'rubric_version' => '0.1.0',
                      'pipeline_version' => '0.1.0-rc1')
        end
        File.open(File.join(@options[:output], 'labels.jsonl'), 'a', 0o600) do |file|
          labels.each { |label| file.puts(JSON.generate(label)) }
          file.flush
          file.fsync
        end
        File.open(File.join(@options[:output], 'requests.jsonl'), 'a', 0o600) do |file|
          file.puts(JSON.generate(sample_ids: batch.map { |r| r['sample_id'] },
                                  model: response[:model], request_id: response[:request_id], usage: response[:usage]))
        end
        @batches_done += 1
        puts JSON.generate(batches: @batches_done, last_batch_rows: labels.size) if @batches_done % 5 == 0
      end
    end

    def record_failure(batch, error)
      @mutex.synchronize do
        item = { sample_ids: batch.map { |r| r['sample_id'] }, error: error.message }
        @failures << item
        File.open(File.join(@options[:output], 'failures.jsonl'), 'a', 0o600) { |file| file.puts(JSON.generate(item)) }
        warn JSON.generate(failed_batch_rows: batch.size, error: error.message)
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { input: 'deliverables/2026-10-21/工具风险预标注与训练-v0.1.0/prepared.jsonl',
              model: 'codex/gpt-6.1-sol', batch_size: 8, workers: 2 }
  OptionParser.new do |parser|
    parser.on('--input PATH') { |v| options[:input] = v }
    parser.on('--output PATH') { |v| options[:output] = v }
    parser.on('--model MODEL') { |v| options[:model] = v }
    parser.on('--limit N', Integer) { |v| options[:limit] = v }
    parser.on('--workers N', Integer) { |v| options[:workers] = v }
    parser.on('--batch-size N', Integer) { |v| options[:batch_size] = v }
    parser.on('--development-only') { options[:development_only] = true }
  end.parse!
  abort '--output is required' unless options[:output]
  DecisionData::AnnotationRun.new(options).run
end
