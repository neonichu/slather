require 'fileutils'
require 'xcodeproj'
require 'json'
require 'yaml'
require 'shellwords'

module Xcodeproj

  class Project

    def slather_setup_for_coverage(format = :auto)
      unless [:gcov, :clang, :auto].include?(format)
        raise StandardError, "Only supported formats for setup are gcov, clang or auto"
      end
      if format == :auto
        format = Slather.xcode_version[0] < 7 ? :gcov : :clang
      end

      build_configurations.each do |build_configuration|
        if format == :clang
          build_configuration.build_settings["CLANG_ENABLE_CODE_COVERAGE"] = "YES"
        else
          build_configuration.build_settings["GCC_INSTRUMENT_PROGRAM_FLOW_ARCS"] = "YES"
          build_configuration.build_settings["GCC_GENERATE_TEST_COVERAGE_FILES"] = "YES"
        end
      end

      # Patch xcschemes too
      if format == :clang
        if Gem::Requirement.new('~> 0.27') =~ Gem::Version.new(Xcodeproj::VERSION)
          # @todo This will require to bump the xcodeproj dependency to ~> 0.27
          # (which would require to bump cocoapods too)
          schemes_path = Xcodeproj::XCScheme.shared_data_dir(self.path)
          Xcodeproj::Project.schemes(self.path).each do |scheme_name|
            xcscheme_path = "#{schemes_path + scheme_name}.xcscheme"
            xcscheme = Xcodeproj::XCScheme.new(xcscheme_path)
            xcscheme.test_action.xml_element.attributes['codeCoverageEnabled'] = 'YES'
            xcscheme.save_as(self.path, scheme_name)
          end
        else
          # @todo In the meantime, simply inform the user to do it manually
          puts %Q(Ensure you enabled "Gather coverage data" in each of your scheme's Test action)
        end
      end
    end

  end
end

module Slather
  class Project < Xcodeproj::Project

    attr_accessor :build_directory, :ignore_list, :ci_service, :coverage_service, :coverage_access_token, :source_directory, 
      :output_directory, :xcodeproj, :show_html, :verbose_mode, :input_format, :scheme, :binary_file, :binary_basename

    alias_method :setup_for_coverage, :slather_setup_for_coverage

    def self.open(xcodeproj)
      proj = super
      proj.xcodeproj = xcodeproj
      proj
    end

    def derived_data_path
      File.expand_path('~') + "/Library/Developer/Xcode/DerivedData/"
    end
    private :derived_data_path

    def coverage_files
      if self.input_format == "profdata"
        profdata_coverage_files
      else
        gcov_coverage_files
      end
    end
    private :coverage_files

    def gcov_coverage_files
      coverage_files = Dir["#{build_directory}/**/*.gcno"].map do |file|
        coverage_file = coverage_file_class.new(self, file)
        # If there's no source file for this gcno, it probably belongs to another project.
        coverage_file.source_file_pathname && !coverage_file.ignored? ? coverage_file : nil
      end.compact

      if coverage_files.empty?
        raise StandardError, "No coverage files found. Are you sure your project is setup for generating coverage files? Try `slather setup your/project.xcodeproj`"
      else
        dedupe(coverage_files)
      end
    end
    private :gcov_coverage_files

    def profdata_coverage_files
      files = profdata_llvm_cov_output.split("\n\n")

      files.map do |source|
        coverage_file = coverage_file_class.new(self, source)
        !coverage_file.ignored? ? coverage_file : nil
      end.compact
    end
    private :profdata_coverage_files

    def profdata_coverage_dir
      raise StandardError, "The specified build directory (#{self.build_directory}) does not exist" unless File.exists?(self.build_directory)
      dir = nil
      if self.scheme
        dir = Dir["#{build_directory}/**/CodeCoverage/#{self.scheme}"].first
      else
        dir = Dir["#{build_directory}/**/#{self.products.first.name}"].first
      end

      raise StandardError, "No coverage directory found. Are you sure your project is setup for generating coverage files? Try `slather setup your/project.xcodeproj`" unless dir != nil
      dir
    end

    def profdata_file
      profdata_coverage_dir = self.profdata_coverage_dir
      if profdata_coverage_dir == nil
        raise StandardError, "No coverage directory found. Please make sure the \"Code Coverage\" checkbox is enabled in your scheme's Test action or the build_directory property is set."
      end

      file =  Dir["#{profdata_coverage_dir}/**/Coverage.profdata"].first
      unless file != nil
        return nil
      end
      return File.expand_path(file)
    end
    private :profdata_file

    def find_binary_file_for_app(app_bundle_file)
      app_bundle_file_name_noext = Pathname.new(app_bundle_file).basename.to_s.gsub(".app", "")
      Dir["#{app_bundle_file}/**/#{app_bundle_file_name_noext}"].first
    end

    def find_binary_file_for_dynamic_lib(framework_bundle_file)
      framework_bundle_file_name_noext = Pathname.new(framework_bundle_file).basename.to_s.gsub(".framework", "")
      "#{framework_bundle_file}/#{framework_bundle_file_name_noext}"
    end

    def find_binary_file_for_static_lib(xctest_bundle_file)
      xctest_bundle_file_name_noext = Pathname.new(xctest_bundle_file).basename.to_s.gsub(".xctest", "")
      Dir["#{xctest_bundle_file}/**/#{xctest_bundle_file_name_noext}"].first
    end

    def unsafe_profdata_llvm_cov_output
      profdata_file_arg = profdata_file
      if profdata_file_arg == nil
        raise StandardError, "No Coverage.profdata files found. Please make sure the \"Code Coverage\" checkbox is enabled in your scheme's Test action or the build_directory property is set."
      end

      if self.binary_file == nil
        raise StandardError, "No binary file found."
      end

      llvm_cov_args = %W(show -instr-profile #{profdata_file_arg} #{self.binary_file})
      `xcrun llvm-cov #{llvm_cov_args.shelljoin}`
    end
    private :unsafe_profdata_llvm_cov_output

    def profdata_llvm_cov_output
      unsafe_profdata_llvm_cov_output.encode!('UTF-8', 'binary', :invalid => :replace, undef: :replace)
    end
    private :profdata_llvm_cov_output

    def dedupe(coverage_files)
      coverage_files.group_by(&:source_file_pathname).values.map { |cf_array| cf_array.max_by(&:percentage_lines_tested) }
    end
    private :dedupe

    def self.yml_filename
      '.slather.yml'
    end

    def self.yml
      @yml ||= File.exist?(yml_filename) ? YAML.load_file(yml_filename) : {}
    end

    def configure
      configure_build_directory
      configure_ignore_list
      configure_ci_service
      configure_coverage_access_token
      configure_coverage_service
      configure_source_directory
      configure_output_directory
      configure_input_format
      configure_scheme
      configure_binary_file

      if self.verbose_mode
        puts "\nProcessing coverage file: #{profdata_file}"
        puts "Against binary file: #{self.binary_file}\n\n"
      end
    end

    def configure_build_directory
      self.build_directory ||= self.class.yml["build_directory"] || derived_data_path
    end

    def configure_source_directory
      self.source_directory ||= self.class.yml["source_directory"] if self.class.yml["source_directory"]
    end

    def configure_output_directory
      self.output_directory ||= self.class.yml["output_directory"] if self.class.yml["output_directory"]
    end

    def configure_ignore_list
      self.ignore_list ||= [(self.class.yml["ignore"] || [])].flatten
    end

    def configure_ci_service
      self.ci_service ||= (self.class.yml["ci_service"] || :travis_ci)
    end

    def configure_input_format
      self.input_format ||= self.class.yml["input_format"] || input_format
    end

    def input_format=(format)
      format ||= "auto"
      unless %w(gcov profdata auto).include?(format)
        raise StandardError, "Only supported input formats are gcov, profdata or auto"
      end
      if format == "auto"
        @input_format = Slather.xcode_version[0] < 7 ? "gcov" : "profdata"
      else
        @input_format = format
      end
    end

    def configure_scheme
      self.scheme ||= self.class.yml["scheme"] if self.class.yml["scheme"]
    end

    def ci_service=(service)
      @ci_service = service && service.to_sym
    end

    def configure_coverage_service
      self.coverage_service ||= (self.class.yml["coverage_service"] || :terminal)
    end

    def configure_coverage_access_token
      self.coverage_access_token ||= (ENV["COVERAGE_ACCESS_TOKEN"] || self.class.yml["coverage_access_token"] || "")
    end

    def coverage_service=(service)
      service = service && service.to_sym
      if service == :coveralls
        extend(Slather::CoverageService::Coveralls)
      elsif service == :hardcover
        extend(Slather::CoverageService::Hardcover)
      elsif service == :terminal
        extend(Slather::CoverageService::SimpleOutput)
      elsif service == :gutter_json
        extend(Slather::CoverageService::GutterJsonOutput)
      elsif service == :cobertura_xml
        extend(Slather::CoverageService::CoberturaXmlOutput)
      elsif service == :html
        extend(Slather::CoverageService::HtmlOutput)
      else
        raise ArgumentError, "`#{coverage_service}` is not a valid coverage service. Try `terminal`, `coveralls`, `gutter_json`, `cobertura_xml` or `html`"
      end
      @coverage_service = service
    end

    def configure_binary_file
      if self.input_format == "profdata"
        self.binary_file ||= self.class.yml["binary_file"] || File.expand_path(find_binary_file)
      end
    end

    def find_binary_file
      xctest_bundle = Dir["#{profdata_coverage_dir}/**/*.xctest"].reject { |bundle|
        bundle.include? "-Runner.app/PlugIns/"
      }.first
      raise StandardError, "No product binary found in #{profdata_coverage_dir}. Are you sure your project is setup for generating coverage files? Try `slather setup your/project.xcodeproj`" unless xctest_bundle != nil

      # Find the matching binary file
      search_for = self.binary_basename || self.class.yml["binary_basename"] || '*'
      xctest_bundle_file_directory = Pathname.new(xctest_bundle).dirname
      app_bundle = Dir["#{xctest_bundle_file_directory}/#{search_for}.app"].first
      dynamic_lib_bundle = Dir["#{xctest_bundle_file_directory}/#{search_for}.framework"].first

      if app_bundle != nil
        find_binary_file_for_app(app_bundle)
      elsif dynamic_lib_bundle != nil
        find_binary_file_for_dynamic_lib(dynamic_lib_bundle)
      else
        find_binary_file_for_static_lib(xctest_bundle)
      end
    end

  end
end
