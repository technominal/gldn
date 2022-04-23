# frozen_string_literal: true

require_relative "gldn/version"
require "thor"

module Gldn
  class Error < StandardError; end

  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    desc "link [app]", "create links for app"
    def link(app)
      puts "Linking #{app}:"
    end
  end
end
