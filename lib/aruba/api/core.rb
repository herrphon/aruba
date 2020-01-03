require 'rspec/expectations'
require 'aruba/runtime'
require 'aruba/errors'
require 'aruba/setup'

# Aruba
module Aruba
  # Api
  module Api
    # Core methods of aruba
    #
    # Those methods do not depend on any other API method of aruba
    module Core
      include ::RSpec::Matchers

      # Aruba Runtime
      def aruba
        # TODO: Check this variable being accessed inconsistently. Should only be using the memo!
        # Renaming this to `aruba` causes 100's of rspec failures. Needs a deeper dive, approach with caution!
        @_aruba_runtime ||= Runtime.new
      end

      # Clean the working directory of aruba
      #
      # This will only clean up aruba's working directory to remove all
      # artifacts of your tests. This does NOT clean up the current working
      # directory.
      def setup_aruba(clobber = true)
        Aruba::Setup.new(aruba).call(clobber)

        self
      end

      # Execute block in Aruba's current directory
      #
      # @yield
      #   The block which should be run in current directory
      def in_current_directory(&block)
        create_directory '.' unless directory?('.')
        cd('.', &block)
      end

      # Switch to directory
      #
      # @param [String] dir
      #   The directory
      #
      # @example Normal directory
      #   cd 'dir'
      #
      # @example Move up
      #   cd '..'
      #
      # @example Run code in directory
      #   result = cd('some-dir') { Dir.getwd }
      #
      # rubocop:disable Metrics/MethodLength
      def cd(dir, &block)
        if block_given?
          begin
            unless Aruba.platform.directory?(expand_path(dir))
              raise ArgumentError, "#{expand_path(dir)} is not a directory or does not exist."
            end

            old_directory = expand_path('.')
            aruba.current_directory << dir
            new_directory = expand_path('.')

            aruba.event_bus.notify Events::ChangedWorkingDirectory.new(old: old_directory, new: new_directory)

            old_dir = Aruba.platform.getwd

            Aruba.platform.chdir File.join(aruba.root_directory, aruba.current_directory)

            result = with_environment(
              'OLDPWD' => old_dir,
              'PWD' => File.expand_path(File.join(aruba.root_directory, aruba.current_directory)),
              &block
            )
          ensure
            aruba.current_directory.pop
            Aruba.platform.chdir old_dir
          end

          return result
        end

        raise ArgumentError, "#{expand_path(dir)} is not a directory or does not exist." unless Aruba.platform.directory?(expand_path(dir))

        old_directory = expand_path('.')
        aruba.current_directory << dir
        new_directory = expand_path('.')

        aruba.event_bus.notify Events::ChangedWorkingDirectory.new(old: old_directory, new: new_directory)

        self
      end
      # rubocop:enable Metrics/MethodLength

      # Expand file name
      #
      # @param [String] file_name
      #   Name of file
      #
      # @param [String] dir_string
      #   Name of directory to use as starting point, otherwise current directory is used.
      #
      # @return [String]
      #   The full path
      #
      # @example Single file name
      #
      #   # => <path>/tmp/aruba/file
      #   expand_path('file')
      #
      # @example Single Dot
      #
      #   # => <path>/tmp/aruba
      #   expand_path('.')
      #
      # @example using home directory
      #
      #   # => <path>/home/<name>/file
      #   expand_path('~/file')
      #
      # @example using fixtures directory
      #
      #   # => <path>/test/fixtures/file
      #   expand_path('%/file')
      #
      # @example Absolute directory
      #
      #   # => /foo/bar
      #   expand_path('/foo/bar')
      #
      # rubocop:disable Metrics/MethodLength
      # rubocop:disable Metrics/CyclomaticComplexity
      # rubocop:disable Metrics/PerceivedComplexity
      def expand_path(file_name, dir_string = nil)
        message = "Filename #{file_name} needs to be a string. It cannot be nil or empty either. "\
          "Please use `expand_path('.')` if you want the current directory to be expanded."

        fail ArgumentError, message unless file_name.is_a?(String) && !file_name.empty?

        # rubocop:disable Layout/LineLength
        fail %(Aruba's working directory does not exist. Maybe you forgot to run `setup_aruba` before using its API.) unless Aruba.platform.directory? File.join(aruba.config.root_directory, aruba.config.working_directory)

        # rubocop:enable Layout/LineLength

        prefix = file_name[0]
        rest = file_name[2..-1]

        if aruba.config.fixtures_path_prefix == prefix
          path = File.join(*[aruba.fixtures_directory, rest].compact)
          unless Aruba.platform.exist? path
            raise ArgumentError, "Fixture #{rest} does not exist in fixtures directory #{aruba.fixtures_directory}. "\
              "This was the one we found first on your system from all possible candidates: #{aruba_fixture_candidates}."
          end

          path
        elsif prefix == '~'
          path = with_environment do
            ArubaPath.new(File.expand_path(file_name))
          end

          raise ArgumentError, 'Expanding "~/" to "/" is not allowed' if path.to_s == '/'
          raise ArgumentError, "Expanding '~/' to a relative path #{path} is not allowed" unless path.absolute?

          path.to_s
        elsif absolute?(file_name)
          unless aruba.config.allow_absolute_paths
            caller_location = caller_locations(1, 1).first
            caller_file_line = "#{caller_location.path}:#{caller_location.lineno}"
            aruba.logger.warn "Aruba's `expand_path` method was called with an absolute path at #{caller_file_line}"\
              ', which is not recommended. Change the call to pass a relative path or set '\
              '`config.allow_absolute_paths = true` to silence this warning'
          end
          file_name
        else
          directory = File.join(aruba.root_directory, aruba.current_directory)
          directory = File.expand_path(dir_string, directory) if dir_string
          File.expand_path(file_name, directory)
        end
      end
      # rubocop:enable Metrics/MethodLength
      # rubocop:enable Metrics/CyclomaticComplexity
      # rubocop:enable Metrics/PerceivedComplexity

      # Run block with environment
      #
      # @param [Hash] env (optional)
      #   The variables to be used for block.
      #
      # @yield
      #   The block of code which should be run with the changed environment variables
      def with_environment(env = {}, &block)
        old_aruba_env = aruba.environment.to_h

        # make sure the old environment is really restored in "ENV"
        Aruba.platform.with_environment aruba.environment.update(env).to_h, &block
      ensure
        # make sure the old environment is really restored in "aruba.environment"
        aruba.environment.clear
        aruba.environment.update old_aruba_env
      end

      private

      def aruba_fixture_candidates
        aruba.config.fixtures_directories.map { |p| format('"%s"', p) }.join(', ')
      end
    end
  end
end
