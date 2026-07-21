require "net/http"
require "json"
require "uri"

class LylaClient
  class Error < StandardError; end

  def initialize(base_url: ENV.fetch("LYLA_API_URL"), token: ENV.fetch("LYLA_API_TOKEN"))
    @base_url = base_url
    @token = token
  end

  def cases(status: nil)
    request(:get, "/api/v1/cases", params: status ? { status: status } : nil)
  end

  def find_case(case_number)
    request(:get, "/api/v1/cases/#{case_number}")
  end

  def create_case_action(fields)
    request(:post, "/api/v1/case-actions", body: fields)
  end

  def case_actions_for_member(user_id, limit: 20)
    request(:get, "/api/v1/members/#{user_id}/case-actions", params: { limit: limit })
  end

  def notes_for_member(user_id)
    request(:get, "/api/v1/members/#{user_id}/notes")
  end

  def create_note(user_id, body:, created_by:)
    request(:post, "/api/v1/members/#{user_id}/notes", body: { body: body, created_by: created_by })
  end

  private

  def request(method, path, params: nil, body: nil)
    uri = URI.join(@base_url, path)
    uri.query = URI.encode_www_form(params) if params

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"

    req = build_request(method, uri, body)
    req["Authorization"] = "Bearer #{@token}"
    req["Content-Type"] = "application/json" if body

    handle_response(http.request(req))
  end

  def build_request(method, uri, body)
    klass = { get: Net::HTTP::Get, post: Net::HTTP::Post }.fetch(method)
    req = klass.new(uri)
    req.body = body.to_json if body
    req
  end

  def handle_response(response)
    case response
    when Net::HTTPNotFound
      nil
    when Net::HTTPSuccess
      JSON.parse(response.body)
    else
      raise Error, "Lyla API error #{response.code}: #{response.body}"
    end
  end
end
