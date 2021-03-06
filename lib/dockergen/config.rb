require 'yaml'

module DockerGen
  module Build
    class Config
      attr_reader :def_base_dir
      attr_reader :build_dir
      attr_reader :stdout
      attr_reader :force_update
      attr_reader :definition
      attr_reader :snippet_sources
      attr_accessor :logger

      def initialize(opts)
        opts = {
          def_yaml: File.join(Dir.getwd, 'definition.yml'),
          build_dir: File.join(Dir.getwd, 'build'),
          stdout: false,
          definition: nil,
          force: false
        }.merge(opts || {})
        @def_yaml = opts[:def_yaml]
        @stdout = opts[:stdout]
        @force_update = opts[:force]
        @build_dir = opts[:build_dir]
        @definition = YAML.load_file(@def_yaml)
        @def_base_dir = File.expand_path(File.dirname(@def_yaml))
        valid_keys = ['snippet_sources', 'dockerfile', 'docker_opts', 'assets']
        invalid = (@definition.keys - valid_keys)
        unless invalid.empty?
          msg = "invalid key(s) in definition file: '#{invalid.join("', '")}'"
          raise DockerGen::Errors::InvalidDefinitionFile.new(msg)
        end
        sources = @definition['snippet_sources'] || []
        sources = [sources] if sources.is_a? String
        @snippet_sources = sources.map do |src|
          if src[0] == '/'
            next src
          else
            next File.expand_path(File.join(@def_base_dir, src))
          end
        end
      end
    end
  end
end
