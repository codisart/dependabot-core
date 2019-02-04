# frozen_string_literal: true

module Dependabot
  module Clients
    module Credentials
      class AccessToken
        def initialize(credentials:, hostname:)
          @access_token = credentials.
            select { |cred| cred["type"] == "git_source" }.
            find { |cred| cred["host"] == hostname }&.
            fetch("password")
        end

        def access_token
          access_token || ""
        end
      end
    end
  end
end
