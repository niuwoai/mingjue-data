# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module DecisionData
  class ModelClient
    def initialize(model:, timeout: 180)
      settings = JSON.parse(File.read(File.expand_path('~/.claude/settings.json'))).fetch('env')
      @base = settings.fetch('ANTHROPIC_BASE_URL')
      @token = settings.fetch('ANTHROPIC_AUTH_TOKEN')
      @model = model
      @timeout = timeout
    end

    def completion(system, records)
      uri = URI(@base.sub(%r{/$}, '') + '/v1/chat/completions')
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{@token}"
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(payload(system, records))
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = @timeout
      response = http.request(request)
      unless response.code == '200'
        detail = JSON.parse(response.body).dig('error', 'message').to_s
        detail = detail.gsub(/[A-Za-z0-9_\/=.+-]{28,}/, '[REDACTED]')[0, 250]
        raise "Model gateway HTTP #{response.code}: #{detail}"
      end

      parse_response(response.body)
    end

    private

    def payload(system, records)
      result = {
        model: @model, stream: false, max_tokens: 12_000,
        messages: [{ role: 'system', content: system },
                   { role: 'user', content: JSON.generate(records: records) }],
      }
      result[:response_format] = { type: 'json_object' } unless @model.include?('claude')
      result[:reasoning_effort] = 'low' if @model.include?('gpt-')
      result
    end

    def parse_response(body)
      response = JSON.parse(body)
      choice = response.fetch('choices').first
      raise 'Output truncated' if choice.fetch('finish_reason') == 'length'

      content = choice.fetch('message').fetch('content')
      text = content.is_a?(Array) ? content.map { |part| part['text'] }.join : content
      text = text.sub(/\A\s*```(?:json)?\s*/i, '').sub(/\s*```\s*\z/, '')
      { labels: JSON.parse(text).fetch('labels'), model: response['model'],
        usage: response['usage'], request_id: response['id'] }
    end
  end
end
