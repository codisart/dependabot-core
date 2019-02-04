# frozen_string_literal: true

require "dependabot/clients/bitbucket"
require "dependabot/clients/github_with_retries"
require "dependabot/clients/gitlab"

module Dependabot
  module Clients
    class Factory

        def self.select_client(provider)
          case source.provider
          when "github"
            Dependabot::Client::GithubWithRetries
          when "gitlab"
            Dependabot::Client::GitLab
          when "bitbucket"
            Dependabot::Client::Bitbucket
          else raise "Unsupported provider '#{provider}'."
          end
        end
    end
  end
end
