# frozen_string_literal: true

require "dependabot/dependency_file"
require "dependabot/source"
require "dependabot/errors"
require "dependabot/clients/github_with_retries"
require "dependabot/clients/bitbucket"
require "dependabot/clients/factory"
require "dependabot/clients/gitlab"
require "dependabot/shared_helpers"

module Dependabot
  module FileFetchers
    class Base
      attr_reader :source, :credentials

      ClientFactory = Dependabot::Clients::Factory

      def self.required_files_in?(_filename_array)
        raise NotImplementedError
      end

      def self.required_files_message
        raise NotImplementedError
      end

      def initialize(source:, credentials:)
        @source = source
        @credentials = credentials

        @submodule_directories = {}
      end

      def repo
        source.repo
      end

      def directory
        source.directory || "/"
      end

      def target_branch
        source.branch
      end

      def files
        @files ||= fetch_files
      end

      def commit
        branch = target_branch || default_branch_for_repo

        @commit ||= client_for_provider.fetch_commit(repo, branch)
      rescue Octokit::NotFound, Gitlab::Error::NotFound,
             Dependabot::Clients::Bitbucket::NotFound
        raise Dependabot::BranchNotFound, branch
      rescue Octokit::Conflict => error
        raise unless error.message.include?("Repository is empty")
      end

      private

      def default_branch_for_repo
        @default_branch_for_repo ||=
          client_for_provider.fetch_default_branch(repo)
      rescue Octokit::NotFound, Gitlab::Error::NotFound,
             Dependabot::Clients::Bitbucket::NotFound
        raise Dependabot::RepoNotFound, source
      end

      def fetch_file_if_present(filename)
        dir = File.dirname(filename)
        basename = File.basename(filename)
        return unless repo_contents(dir: dir).map(&:name).include?(basename)

        fetch_file_from_host(filename)
      rescue Octokit::NotFound, Gitlab::Error::NotFound,
             Dependabot::Clients::Bitbucket::NotFound
        path = Pathname.new(File.join(directory, filename)).cleanpath.to_path
        raise Dependabot::DependencyFileNotFound, path
      end

      def fetch_file_from_host(filename, type: "file")
        path = Pathname.new(File.join(directory, filename)).cleanpath.to_path

        DependencyFile.new(
          name: Pathname.new(filename).cleanpath.to_path,
          content: fetch_file_content(path),
          directory: directory,
          type: type
        )
      rescue Octokit::NotFound, Gitlab::Error::NotFound,
             Dependabot::Clients::Bitbucket::NotFound
        raise Dependabot::DependencyFileNotFound, path
      end

      def fetch_file_from_host_or_submodule(filename, type: "file")
        fetch_file_from_host(filename, type: type)
      rescue Dependabot::DependencyFileNotFound => error
        begin
          repo_contents(dir: File.dirname(filename))
        rescue StandardError
          raise error
        end

        fetch_file_from_host(filename, type: type)
      end

      def repo_contents(dir: ".", raise_errors: true)
        path = Pathname.new(File.join(directory, dir)).
               cleanpath.to_path.gsub(%r{^/*}, "")

        # Don't fetch contents of repos nested in submodules
        submods = @submodule_directories
        if submods.keys.any? { |k| path.match?(%r{#{Regexp.quote(k)}(/|$)}) }
          return []
        end

        @repo_contents ||= {}
        @repo_contents[dir] ||=
          case source.provider
          when "github"
              github_repo_contents(path)
          when "gitlab"
            client_for_provider.get_repo_contents(repo, commit, path)
          when "bitbucket"
            client_for_provider.get_repo_contents(repo, commit, path)
          else raise "Unsupported provider '#{source.provider}'."
          end
      rescue Octokit::NotFound, Gitlab::Error::NotFound,
             Dependabot::Clients::Bitbucket::NotFound
        raise if raise_errors

        []
      end

      def github_repo_contents(path)
        path = path.gsub(" ", "%20")
        response = client_for_provider.
                          contents(repo, path: path, ref: commit)

        if response.respond_to?(:type) && response.type == "submodule"
          @submodule_directories[path] = response

          sub_source = Source.from_url(response.submodule_git_url)
          response = client_for_provider.
                            contents(sub_source.repo, ref: response.sha)
        elsif response.respond_to?(:type)
          raise Octokit::NotFound
        end

        response.map do |file|
          OpenStruct.new(
            name: file.name,
            path: file.path,
            type: file.type,
            sha: file.sha,
            size: file.size
          )
        end
      end

      def gitlab_repo_contents(path)
        client_for_provider.
          repo_tree(repo, path: path, ref_name: commit, per_page: 100).
          map do |file|
            OpenStruct.new(
              name: file.name,
              path: file.path,
              type: file.type == "blob" ? "file" : file.type,
              size: 0 # GitLab doesn't return file size
            )

          end
      end

      def fetch_file_content(path)
        path = path.gsub(%r{^/*}, "")
        dir = Pathname.new(path).dirname.to_path.gsub(%r{^/*}, "")

        if @submodule_directories.key?(dir)
          return fetch_submodule_file_content(path)
        end

        fetch_file_content(source.provider, path, repo, commit)
      end

      def fetch_submodule_file_content(path)
        path = path.gsub(%r{^/*}, "")
        dir = Pathname.new(path).dirname.to_path.gsub(%r{^/*}, "")
        submodule = @submodule_directories[dir]

        provider = Source.from_url(submodule.submodule_git_url).provider
        repo = Source.from_url(submodule.submodule_git_url).repo
        commit = submodule.sha
        path = path.gsub("#{dir}/", "")

        fetch_file_content(provider, path, repo, commit)
      end

      def fetch_file_content_by_provider(provider, path, repo, commit)
        case provider
          when "github"
            fetch_file_content_from_github(path, repo, commit)
          when "gitlab"
            tmp = client_for_provider.get_file(repo, path, commit).content
            Base64.decode64(tmp).force_encoding("UTF-8").encode
          when "bitbucket"
            bitbucket_client.fetch_file_contents(repo, commit, path)
          else raise "Unsupported provider '#{provider}'."
        end
      end

      # rubocop:disable Metrics/AbcSize
      def fetch_file_content_from_github(path, repo, commit)
        tmp = client_for_provider.contents(repo, path: path, ref: commit)

        if tmp.type == "symlink"
          tmp = client_for_provider.contents(
            repo,
            path: tmp.target,
            ref: commit
          )
        end

        Base64.decode64(tmp.content).force_encoding("UTF-8").encode
      rescue Octokit::Forbidden => error
        raise unless error.message.include?("too_large")

        # Fall back to Git Data API to fetch the file
        prefix_dir = directory.gsub(%r{(^/|/$)}, "")
        dir = File.dirname(path).gsub(%r{^/?#{Regexp.escape(prefix_dir)}/?}, "")
        basename = File.basename(path)
        file_details = repo_contents(dir: dir).find { |f| f.name == basename }
        raise unless file_details

        tmp = client_for_provider.blob(repo, file_details.sha)
        return tmp.content if tmp.encoding == "utf-8"

        Base64.decode64(tmp.content).force_encoding("UTF-8").encode
      end
      # rubocop:enable Metrics/AbcSize

      def client_for_provider
        @client_for_provider ||= build_client
      end

      def bitbucket_client
        @bitbucket_client ||= build_client
      end

      def build_client
        ClientFactory.select_client(source.provider).for_source(
          source: source,
          credentials: credentials
        )
      end

    end
  end
end
