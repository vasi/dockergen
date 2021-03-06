require 'fileutils'

module DockerGen
  module Build
    def self.check_build_definition(definition)
      unless definition['dockerfile']
        msg = "definition contains no 'dockerfile' key"
        raise DockerGen::Errors::InvalidDefinitionFile.new(msg)
      end
      if definition['docker_opts'] && ! definition['docker_opts']['build_tag']
        raise InvalidDefinitionFile.new("docker_opts does not have a build_tag")
      end
      if definition['assets']
        definition['assets'].each do |asset|
          unless asset['filename']
            raise DockerGen::Errors::InvalidDefinitionFile.new("All assets must have a filename")
          end
        end
      end
    end
    class Job
      attr_reader :config
      attr_reader :steps
      attr_reader :actions
      attr_reader :assets

      def initialize(config)
        Build.check_build_definition(config.definition)
        @config = config
        @logger = config.logger
        @docker_opts = @config.definition['docker_opts'] || {}
        @assets = @config.definition['assets'] || []
        @external_files = @assets.map{|a| a['filename']}
        @steps = @config.definition['dockerfile'].map do |definition|
          DockerGen::Build.parse_build_step(definition)
        end
        @required_snippets = @steps.select{|s| s.is_a?(SnippetStep)}
                                   .map{|s| s.snippet}
        @snippets = DockerGen::Build.load_snippets_by_name(@required_snippets,
                                                           @config.snippet_sources,
                                                           @logger)
        @actions = @steps.flat_map do |step|
          if step.is_a? LiteralStep
            next DockerfileEntry.new("Dockerfile entry '#{step.dockerfile}'", step.dockerfile)
          elsif step.is_a? SnippetStep
            next @snippets[step.snippet].interpret(step.vars)
          else
            raise DockerGen::Errors::InvalidBuildStep.new(step.to_s)
          end
        end

        # detect multiple snippets claiming the same context dependency
        files = {}
        @actions.select{|a| a.is_a?(ContextFile)}.each do |action|
          next if !action.contents
          if files.has_key? action.filename
            msg = "Snippets #{action.source_description} and " +
                  "#{files[action.filename]} both want to create #{action.filename}"
            raise DockerGen::Errors::InvalidBuildStep.new(msg)
          else
            files[action.filename] = action.source_description
          end
        end
      end

      public
      def generate
        # check if all external dependencies have a fetch rule
        @actions.select{|a| a.is_a?(ContextFile) && a.external}.each do |a|
          # if a/b has a fetch rule assume it also provides a/b/c
          if @external_files.select{|f| a.filename.index(f) == 0}.empty?
            msg = "no fetch rule given for context dependency '#{a.filename}' (required by #{a.source_description})"
            raise DockerGen::Errors::MissingContextFile.new(msg)
          end
        end

        if @config.build_dir
          Dir.mkdir(@config.build_dir) unless File.exists?(@config.build_dir)
        end
        dockerfile = @actions.select{|a| a.is_a?(DockerfileEntry)}
                             .map{|a| a.dockerfile}
                             .join("\n\n") + "\n"

        update_context('Dockerfile', dockerfile)
        update_context('Makefile', gen_makefile)
        update_context('make/.gitkeep', '')
        update_context('assets/.gitkeep', '')

        @actions.select{|a| a.is_a?(ContextFile) && !a.external}
                .each{|a| update_context(a.filename, a.contents)}
      end

      def update_context(context_path, contents)
        path = File.join(@config.build_dir, context_path)
        write = false
        if File.exists?(path)
          if File.open(path, 'r') { |f| f.read == contents }
            @logger.context(path, 'no-change')
          elsif @config.force_update
            @logger.context(path, 'updated')
            write = true
          else
            @logger.context(path, 'stale')
            @logger.warn "#{path} is out of date, use --force-update to overwrite"
          end
        else
          @logger.context(path, 'created')
          write = true
        end
        if write
          FileUtils.mkdir_p(File.dirname(path))
          File.open(path, 'w') { |fw| fw.write(contents) }
        end
      end

      private
      def gen_makefile
        entries = []
        @assets.each do |a|
          entries << "#{a['filename']}:\n\t#{a['fetch'].strip.gsub(/\n/, "\n\t")}"
        end
        entries << "assets: #{@external_files.join(' ')}"
        opts = @docker_opts['run_opts'] || []
        unless opts.empty?
          entries << "build: assets\n\tdocker build -t #{@docker_opts['build_tag']} ."
          entries << "build_no_cache: assets\n\tdocker build --no-cache -t #{@docker_opts['build_tag']} ."
          entries << "start:\n\tdocker run #{opts.join(' ')} #{@docker_opts['build_tag']}"
        end
        phony = %w[start build build_no_cache]
        entries << ".PHONY: #{phony.join(' ')}"
        entries << "include make/*.mk"
        return entries.join("\n\n") + "\n"
      end
    end
  end
end
