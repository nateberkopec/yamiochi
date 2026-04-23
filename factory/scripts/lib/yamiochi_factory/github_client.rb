# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module YamiochiFactory
  class GitHubClient
    API_URL = "https://api.github.com"

    def initialize(repository: nil, token: ENV["GH_TOKEN"] || ENV["GITHUB_TOKEN"] || token_from_gh_cli)
      @repository = repository || repository_from_env || repository_from_git_remote
      @token = token

      raise ArgumentError, "Could not determine GitHub repository" unless @repository
    end

    attr_reader :repository, :token

    def issue(number)
      get_json("/repos/#{repository}/issues/#{Integer(number)}")
    end

    def pull_request(number)
      get_json("/repos/#{repository}/pulls/#{Integer(number)}")
    end

    def issues(state: "open", per_page: 100)
      get_json("/repos/#{repository}/issues?state=#{state}&per_page=#{Integer(per_page)}")
    end

    def milestones(state: "all", per_page: 100)
      get_json("/repos/#{repository}/milestones?state=#{state}&per_page=#{Integer(per_page)}")
    end

    def create_issue(title:, body:, milestone: nil, labels: [])
      post_json(
        "/repos/#{repository}/issues",
        {
          title:,
          body:,
          milestone:,
          labels:
        }
      )
    end

    def update_issue(number, title: nil, body: nil, milestone: nil)
      patch_json(
        "/repos/#{repository}/issues/#{Integer(number)}",
        {
          title:,
          body:,
          milestone:
        }.compact
      )
    end

    private

    def get_json(path)
      request_json(Net::HTTP::Get, path)
    end

    def post_json(path, payload)
      request_json(Net::HTTP::Post, path, payload:)
    end

    def patch_json(path, payload)
      request_json(Net::HTTP::Patch, path, payload:)
    end

    def request_json(request_class, path, payload: nil)
      uri = URI.join(API_URL, path)
      request = request_class.new(uri)
      request["Accept"] = "application/vnd.github+json"
      request["User-Agent"] = "yamiochi-factory"
      request["Authorization"] = "Bearer #{token}" if token && !token.empty?
      request["Content-Type"] = "application/json" if payload
      request.body = JSON.generate(payload) if payload

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.request(request)
      end

      return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

      raise "GitHub API request failed (#{response.code} #{response.message}) for #{uri}: #{response.body}"
    end

    def repository_from_env
      repository = ENV["GITHUB_REPOSITORY"] || ENV["YAMIOCHI_FACTORY_REPOSITORY"]
      repository&.strip
    end

    def repository_from_git_remote
      origin_url = `git remote get-url origin 2>/dev/null`.strip
      return if origin_url.empty?

      case origin_url
      when %r{\Ahttps://github\.com/(?<repo>.+?)(?:\.git)?\z}
        Regexp.last_match(:repo)
      when %r{\Agit@github\.com:(?<repo>.+?)(?:\.git)?\z}
        Regexp.last_match(:repo)
      end
    end

    def token_from_gh_cli
      token = `gh auth token 2>/dev/null`.strip
      token unless token.empty?
    end
  end
end
