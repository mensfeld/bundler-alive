# frozen_string_literal: true

require "octokit"
require "json"

module Bundler
  module Alive
    module Client
      #
      # API Client for GitHub API
      #
      # @see https://docs.github.com/en/rest/search#search-repositories
      #
      module GitHubApi
        # Environment variable name of GitHub Access Token
        ACCESS_TOKEN_ENV_NAME = "BUNDLER_ALIVE_GITHUB_TOKEN"

        # Separator of query condition
        QUERY_CONDITION_SEPARATOR = " "

        # Number of attempts to request after too many requests
        RETRIES_ON_TOO_MANY_REQUESTS = 3

        # Interval second when retrying request
        RETRY_INTERVAL_SEC_ON_TOO_MANY_REQUESTS = 120

        #
        # Max number of conditional operator at once
        #
        # @see https://docs.github.com/en/rest/search#limitations-on-query-length
        QUERY_MAX_OPERATORS_AT_ONCE = 6

        private_constant :QUERY_MAX_OPERATORS_AT_ONCE

        def self.extended(base)
          base.instance_eval do
            @rate_limit_exceeded = false
            @retries_on_too_many_requests = 0
          end
        end

        #
        # Creates a GitHub client
        #
        # @return [Octokit::Client]
        #
        def create_client
          Octokit::Client.new(access_token: ENV.fetch(ACCESS_TOKEN_ENV_NAME, nil))
        end

        #
        # Query repository statuses
        #
        # @param [Array<RepositoryUrl>] :urls
        #
        # @return [StatusResult]
        #
        # rubocop:disable Metrics/MethodLength
        def query(urls:)
          collection = StatusCollection.new
          name_with_archived = get_name_with_statuses(urls)
          urls.each do |url|
            yield if block_given?

            gem_name = url.gem_name
            alive = !name_with_archived[gem_name]
            status = Status.new(name: gem_name, repository_url: url, alive: alive, checked_at: Time.now)
            collection = collection.add(gem_name, status)
          end

          StatusResult.new(collection: collection, error_messages: @error_messages,
                           rate_limit_exceeded: @rate_limit_exceeded)
        end
        # rubocop:enable Metrics/MethodLength

        private

        #
        # Search status of repositories
        #
        # @param [Array<RepositoryUrl>] urls
        #
        # @return [Hash<String, Boolean>]
        #   gem name with archived or not
        #
        # rubocop:disable Metrics/MethodLength
        def get_name_with_statuses(urls)
          raise ArgumentError unless urls.instance_of?(Array)

          name_with_status = {}
          urls.each_slice(QUERY_MAX_OPERATORS_AT_ONCE) do |sliced_urls|
            q = search_query(sliced_urls)
            repositories = search_repositories_with_retry(q)
            next if repositories.nil?

            repositories.each do |repository|
              name = repository["name"]
              name_with_status[name] = repository["archived"]
            end
          end
          name_with_status
        end
        # rubocop:enable Metrics/MethodLength

        #
        # Search query of repositories
        #
        # @param [Array<RepositoryUrl>] urls
        #
        # @return [String]
        #
        def search_query(urls)
          urls.map do |url|
            "repo:#{slug(url.url)}"
          end.join(QUERY_CONDITION_SEPARATOR)
        end

        #
        # Search repositories
        #
        # @param [String] query
        #
        # @raise [Octokit::TooManyRequests]
        #   when too many requested to GitHub.com
        # @raise [SourceCodeClient::SearchRepositoryError]
        #   when Error without `Octokit::TooManyRequests`
        #
        # @return [Array<Sawyer::Resource>|nil]
        #
        def search_repositories(query)
          result = @client.search_repositories(query)
          result[:items]
        rescue Octokit::TooManyRequests => e
          raise e
        rescue StandardError => e
          @error_messages << e.message
          []
        end

        def search_repositories_with_retry(query)
          search_repositories(query)
        rescue Octokit::TooManyRequests
          if @retries_on_too_many_requests < RETRIES_ON_TOO_MANY_REQUESTS
            @retries_on_too_many_requests += 1
            sleep_with_message
            retry
          end

          @rate_limit_exceeded = true
          []
        end

        def sleep_with_message
          puts "Too many requested. Sleep #{RETRY_INTERVAL_SEC_ON_TOO_MANY_REQUESTS} sec."
          sleep RETRY_INTERVAL_SEC_ON_TOO_MANY_REQUESTS
          puts "Retry request (#{@retries_on_too_many_requests}/#{RETRIES_ON_TOO_MANY_REQUESTS})"
        end

        #
        # Returns slug of repository URL
        #
        # @param [String] repository_url
        #
        # @return [String]
        #
        def slug(repository_url)
          Octokit::Repository.from_url(repository_url).slug
        end
      end
    end
  end
end
