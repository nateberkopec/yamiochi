# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module YamiochiFactory
  class GitHubClient
    API_URL = "https://api.github.com"

    def initialize(repository: nil, token: ENV["GH_TOKEN"] || ENV["GITHUB_TOKEN"])
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

    private

    def get_json(path)
      uri = URI.join(API_URL, path)
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/vnd.github+json"
      request["User-Agent"] = "yamiochi-factory"
      request["Authorization"] = "Bearer #{token}" if token && !token.empty?

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
  end
end
