# frozen_string_literal: true

require "gitlab"
require "credentials/access_token"

module Dependabot
  module Clients
    class Gitlab
      AccessToken = Dependabot::Client::Credentials::AccessToken

      #######################
      # Constructor methods #
      #######################

      def self.for_source(source:, credentials:)
        access_token = AccessToken.new(credentials, source.hostname).access_token
        new(
          endpoint: source.api_endpoint,
          private_token: access_token
        )
      end

      def self.for_gitlab_dot_com(credentials:)
        access_token = AccessToken.new(credentials, "gitlab.com").access_token
        new(
          endpoint: "https://gitlab.com/api/v4",
          private_token: access_token
        )
      end

      #################
      # VCS Interface #
      #################

      def fetch_commit(repo, branch)
        branch(repo, branch).commit.id
      end

      def fetch_default_branch(repo)
        project(repo).default_branch
      end

      def get_repo_contents(repo, commit, path)
        response = repo_tree(
          repo,
          path: path,
          ref_name: commit,
          per_page: 100
        )

        response.map do |file|
          OpenStruct.new(
            name: file.name,
            path: file.path,
            type: file.type == "blob" ? "file" : file.type,
            size: 0 # GitLab doesn't return file size
          )
        end
      end
      ############
      # Proxying #
      ############

      def initialize(**args)
        @client = ::Gitlab::Client.new(args)
      end

      def method_missing(method_name, *args, &block)
        if @client.respond_to?(method_name)
          mutatable_args = args.map(&:dup)
          @client.public_send(method_name, *mutatable_args, &block)
        else
          super
        end
      end

      def respond_to_missing?(method_name, include_private = false)
        @client.respond_to?(method_name) || super
      end
    end
  end
end
