# frozen_string_literal: true

require_relative "gldn/version"
require "thor"
require "fileutils"
require "find"
require "yaml"

module Gldn
  class Error < StandardError; end

  class CLI < Thor

    def initialize(*args)
      super
      # Load master configuration
      @source = File.expand_path(ENV['GLDN_SRC_PATH'] || Dir.pwd)
      cfgpath = File.join(@source, ".gldnrc.yml")
      unless File.exist?(cfgpath)
        raise Error, "Golden needs a configuration file to work. No config file found at '#{cfgpath}'."
      end

      @config = YAML.load_file(cfgpath)
      raise Error, "Target path not configured. Expected 'target' key par in config file." unless @config.key?("target")
      @appconfig = {}

      @target = File.expand_path(@config["target"] || ENV['GLDN_TARGET_PATH'] || "~/.config")
    end

    def self.exit_on_failure?
      true
    end

    no_tasks do
      def ignore_file?(filename)
        ignores = []
        if @appconfig.has_key?("ignore!")
          ignores = @appconfig["ignore!"].dup()
        elsif @appconfig.has_key?("ignore")
          ignores = @config["ignore"].dup()
          ignores.concat(@appconfig["ignore"])
        else
          ignores = @config["ignore"].dup()
        end
        ignores.push(".gldnrc.yml") # always ignore this tool's config files
        ignores.each do |pattern|
          return true if File.fnmatch(pattern, filename)
        end
        return false
      end

      def child_of?(child, ignored_parents)
        ignored_parents.each do |parent|
          return true if child.start_with?(parent)
        end
        return false
      end

      def intercept_dispatch(command, trailing)
        puts "INTERCEPT!"
        super
      end

      def invoke_command(command, trailing)
        if command.name.eql?("tree") && trailing.empty?
          trailing.push(".")
        elsif command.name.eql?("ls") && trailing.empty?
          trailing.push(".")
        elsif trailing.length == 1 && trailing[0].eql?('.')
          # prevent linking at the root level. Linking should
          # operate on one folder/application at a time.
          trailing = []
        end
        super
      rescue Thor::InvocationError => e
        puts e.message
      rescue Gldn::Error => e
        puts "ERROR: #{e.message}"
      rescue StandardError => e
        puts "#{e.class} Error: #{e.message}"
        puts "Call Stack: #{e.backtrace.join("\n")}"
      end


    end

    desc "source", "print the source directory where Golden expects to find application configurations"
    def source
      puts @source
    end

    desc "target", "print the target directory where Golden expects to create links to configurations sources"
    def target
      puts @target
    end


    desc "ls-all", "list all source applications"
    option :recurse, aliases: '-r', type: :boolean, default: false, desc: "list all applicationsSuppress all output"
    def list_all
      entries = Dir.entries(@source)[2..-1] # skip '.' and '..'
      entries.each do |entry|
        if File.directory?(entry) && !ignore_file?(entry)
          puts entry
        end
      end
    end

    desc "ls-all", "list all application directories"
    def ls_all
      entries = Dir.entries(@source)[2..-1] # skip '.' and '..'
      entries.each do |entry|
        if File.directory?(entry) && !ignore_file?(entry)
          puts entry
        end
      end
    end

    desc "link-all", "create links for all apps"
    option :quiet, aliases: '-q', type: :boolean, default: false, desc: "Suppress all output"
    def link_all
      entries = Dir.entries(@source)[2..-1] # skip '.' and '..'
      entries.each do |entry|
        if File.directory?(entry) && !ignore_file?(entry)
          puts "=> Linking: #{entry}" if !options[:quiet]
          Gldn::CLI.new.invoke :link, [entry], options
        end
      end
    end

    desc "unlink-all", "remove links for all apps"
    option :quiet, aliases: '-q', type: :boolean, default: false, desc: "Suppress all output"
    def unlink_all
      entries = Dir.entries(@source)[2..-1] # skip '.' and '..'
      entries.each do |entry|
        if File.directory?(entry) && !ignore_file?(entry)
          puts "=> Unlinking: #{entry}" if !options[:quiet]
          Gldn::CLI.new.invoke :unlink, [entry], options
        end
      end
    end

    desc "relink-all", "removal links for all apps and then recreate them for all apps"
    option :quiet, aliases: '-q', type: :boolean, default: false, desc: "Suppress all output"
    def relink_all
      entries = Dir.entries(@source)[2..-1] # skip '.' and '..'
      entries.each do |entry|
        if File.directory?(entry) && !ignore_file?(entry)
          puts "=> Relinking: #{entry}" if !options[:quiet]
          Gldn::CLI.new.invoke :relink, [entry], options
        end
      end
    end


    desc "ls [app]", "list the contents of the application"
    def ls(app)
      apppath = File.join(@source, app)
      system("ls -alR #{apppath}")
    end

    desc "tree [app]", "list the contents of the application as a tree"
    def tree(app)
      apppath = File.join(@source, app)
      system("tree #{apppath}")
    end


    desc "link [app]", "create links for specified app"
    option :quiet, aliases: '-q', type: :boolean, default: false, desc: "Suppress all output"
    def link(app)
      if !File.exist?(@target)
        begin
          FileUtils.mkdir_p @target
        rescue StandardError => e
          raise Error,
                "Failed to create directory at target path '#{@target}'. Received error: #{e.message} [#{e.class}]"
        end
      elsif !File.directory?(@target)
        raise Error, "Target path exists but it is not a directory.  Target must be a directory: '#{@target}'."
      end

      sourcelen = @source.length
      apppath = File.join(@source, app)

      # Load sub-configuration
      cfgpath = File.join(apppath, ".gldnrc.yml")
      if File.exist?(cfgpath)
        @appconfig = YAML.load_file(cfgpath)
      end


      dirs_created = 0
      symlinks_created = 0
      applen = apppath.length
      ignored_parents = []
      Find.find(apppath) do |srcpath|
        basename = srcpath[applen+1..-1] || ''
        if ignore_file?(basename)
          if File.directory?(srcpath)
            ignored_parents.push(srcpath.end_with?(File::SEPARATOR) ? srcpath : srcpath + File::Separator)
          end
          next
        elsif child_of?(srcpath, ignored_parents)
          next
        end
        right = srcpath.length - sourcelen - 1
        relpath = srcpath[-right..-1]
        linkpath = File.join(@target, relpath)
        linkpath.gsub!(/\/dot-/, "/.")
        if File.exist?(linkpath)
          # If file already exists at the link path, make sure it is the right type of file
          if File.directory?(srcpath)
            unless File.directory?(linkpath)
              raise Error,
                    "File '#{srcpath}' is a directory in the source, but exists in the target as a file or symlink at '#{linkpath}'."
            end
          elsif File.file?(srcpath)
            if File.directory?(linkpath)
              raise Error,
                    "File '#{srcpath}' is a file in the source, but exists in the target as a directory at '#{linkpath}'."
            elsif File.symlink?(linkpath)
              actual = File.readlink(linkpath)
              unless srcpath.eql?(actual)
                raise Error,
                      "The target contains a bad symlink. The symlink at '#{linkpath}' points to '#{actual}', when it should point to '#{srcpath}'."
              end
            end
          end
        elsif File.directory?(srcpath)
          FileUtils.mkdir_p(linkpath)
          dirs_created += 1
        else
          File.symlink(srcpath, linkpath)
          symlinks_created += 1
        end
      end
      if !options[:quiet]
        if dirs_created > 0 || symlinks_created > 0
          puts "Folders Created : #{dirs_created}"
          puts "Symlinks Created: #{symlinks_created}"
        else
          puts "You're golden!"
        end
      end
    end

    desc "unlink [app]", "remove links for specified app"
    option :quiet, aliases: '-q', type: :boolean, default: false, desc: "Suppress all output"
    def unlink(app)
      sourcelen = @source.length
      srcpath = File.join(@source, app)
      dirs = []
      dirs_removed = 0
      symlinks_removed = 0

      # First remove all symlinks
      Find.find(srcpath) do |srcpath|
        right = srcpath.length - sourcelen - 1
        relpath = srcpath[-right..-1]
        linkpath = File.join(@target, relpath)
        linkpath.gsub!(/\/dot-/, "/.")
        if File.exist?(linkpath)
          if File.symlink?(linkpath)
            FileUtils.remove_file(linkpath)
            symlinks_removed += 1
          elsif File.directory?(linkpath)
            dirs.unshift(linkpath)
          end
        end
      end

      # Now that all symlinks are removed, remove any empty directories
      dirs.each do |linkpath|
        if File.exist?(linkpath) && File.directory?(linkpath) && Dir.empty?(linkpath)
          FileUtils.remove_dir(linkpath)
          dirs_removed += 1
        end
      end

      if !options[:quiet]
        if dirs_removed > 0 || symlinks_removed > 0
          puts "Folders Removed : #{dirs_removed}"
          puts "Symlinks Removed: #{symlinks_removed}"
        else
          puts "Nothing to remove"
        end
      end
    end

    desc "relink [app]", "First unlink and then link the specified app"
    option :quiet, aliases: '-q', type: :boolean, default: false, desc: "Suppress all output"
    def relink(app)
      invoke :unlink, [app], options
      invoke :link, [app], options
    end

  end
end