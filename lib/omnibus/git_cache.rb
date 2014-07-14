#
# Copyright 2014 Chef Software, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'digest'
require 'fileutils'

module Omnibus
  class GitCache
    include Util
    include Logging

    REQUIRED_GIT_FILES = [
      'HEAD',
      'description',
      'hooks',
      'info',
      'objects',
      'refs',
    ].freeze

    #
    # @return [Software]
    #
    attr_reader :software

    #
    # @param [Software] software
    #   the software this git cache is for
    #
    def initialize(software)
      @software = software
    end

    #
    # The path to the full install_dir cache for the project.
    #
    # @return [String]
    #
    def cache_path
      @cache_path ||= File.join(Config.git_cache_dir, install_dir)
    end

    #
    # Creates the full path if it does not exist already.
    #
    # @return [true, false]
    #   true if the path was created, false otherwise
    #
    def create_cache_path
      if File.directory?(cache_path)
        log.info(log_key) { "Cache path `#{cache_path}' exists, skipping creation" }
        false
      else
        log.info(log_key) { "Creating cache path `#{cache_path}'" }
        FileUtils.mkdir_p(File.dirname(cache_path))
        shellout!("git --git-dir=#{cache_path} init -q")
        true
      end
    end

    #
    # Computes the tag for this cache entry.
    #
    # @return [String]
    #
    def tag
      return @tag if @tag

      log.info(log_key) { "Calculating tag" }

      # Accumulate an array of all the software projects that come before
      # the name and version we are tagging. So if you have
      #
      # build_order = [ 1, 2, 3, 4, 5 ]
      #
      # And we are tagging 3, you would get dep_list = [ 1, 2 ]
      dep_list = software.project.library.build_order.take_while do |dep|
        if dep.name == software.name && dep.version == software.version
          false
        else
          true
        end
      end

      log.debug(log_key) { "dep_list: #{dep_list.inspect}" }

      # This is the list of all the unqiue shasums of all the software build
      # dependencies, including the on currently being acted upon.
      shasums = [dep_list.map(&:shasum), software.shasum].flatten
      suffix  = Digest::SHA256.hexdigest(shasums.join('|'))
      @tag    = "#{software.name}-#{suffix}"

      log.debug(log_key) { "tag: #{@tag}" }

      @tag
    end

    # Create an incremental install path cache for the software step
    def incremental
      log.info(log_key) { 'Performing incremental cache' }

      create_cache_path
      remove_git_dirs

      shellout!(%Q(git --git-dir=#{cache_path} --work-tree=#{install_dir} add -A -f))
      begin
        shellout!(%Q(git --git-dir=#{cache_path} --work-tree=#{install_dir} commit -q -m "Backup of #{tag}"))
      rescue Mixlib::ShellOut::ShellCommandFailed => e
        if e.message !~ /nothing to commit/
          raise
        end
      end
      shellout!(%Q(git --git-dir=#{cache_path} --work-tree=#{install_dir} tag -f "#{tag}"))
    end

    def restore
      log.info(log_key) { 'Performing cache restoration' }

      create_cache_path

      cmd = shellout(%Q(git --git-dir=#{cache_path} --work-tree=#{install_dir} tag -l "#{tag}"))

      restore_me = false
      cmd.stdout.each_line do |line|
        restore_me = true if tag == line.chomp
      end

      if restore_me
        log.debug(log_key) { "Detected tag `#{tag}' can be restored, restoring" }
        shellout!(%Q(git --git-dir=#{cache_path} --work-tree=#{install_dir} checkout -f "#{tag}"))
        true
      else
        log.debug(log_key) { "Could not find tag `#{tag}', skipping restore" }
        false
      end
    end

    #
    # Git caching will attempt to version embedded git directories, partially
    # versioning them. This causes failures on subsequent runs. This method
    # will find git directories and remove them to prevent those errors.
    #
    # @return [true]
    def remove_git_dirs
      log.info(log_key) { "Removing git directories" }

      Dir.glob("#{install_dir}/**/{,.*}/config").reject do |path|
        REQUIRED_GIT_FILES.any? do |required_file|
          !File.exist?(File.join(File.dirname(path), required_file))
        end
      end.each do |path|
        log.info(log_key) { "Removing git dir `#{path}'" }
        FileUtils.rm_rf(File.dirname(path))
      end

      true
    end

    private

    #
    #
    # The installation directory for this software's project. Drive letters are
    # stripped for Windows.
    #
    # @return [String]
    #
    def install_dir
      @install_dir ||= software.project.install_dir.sub(/^([A-Za-z]:)/, '')
    end

    # Override the log_key for this class to include the software name
    #
    # @return [String]
    def log_key
      @log_key ||= "#{super}: #{software.name}"
    end
  end
end