#--
# Copyright 2006 by Chad Fowler, Rich Kilmer, Jim Weirich and others.
# All rights reserved.
# See LICENSE.txt for permissions.
#++

require 'rubygems/exceptions'
require 'rubygems/package'
require 'rubygems/ext'
require 'rubygems/user_interaction'
require 'fileutils'

##
# The installer installs the files contained in the .gem into the Gem.home.
#
# Gem::Installer does the work of putting files in all the right places on the
# filesystem including unpacking the gem into its gem dir, installing the
# gemspec in the specifications dir, storing the cached gem in the cache dir,
# and installing either wrappers or symlinks for executables.
#
# The installer invokes pre and post install hooks.  Hooks can be added either
# through a rubygems_plugin.rb file in an installed gem or via a
# rubygems/defaults/#{RUBY_ENGINE}.rb or rubygems/defaults/operating_system.rb
# file.  See Gem.pre_install and Gem.post_install for details.

class Gem::Installer

  ##
  # Paths where env(1) might live.  Some systems are broken and have it in
  # /bin

  ENV_PATHS = %w[/usr/bin/env /bin/env]

  ##
  # Raised when there is an error while building extensions.
  #
  class ExtensionBuildError < Gem::InstallError; end

  include Gem::UserInteraction

  # DOC: Missing docs or :nodoc:.
  attr_reader :gem

  ##
  # The directory a gem's executables will be installed into

  attr_reader :bin_dir

  ##
  # The gem repository the gem will be installed into

  attr_reader :gem_home

  ##
  # The options passed when the Gem::Installer was instantiated.

  attr_reader :options

  @path_warning = false

  class << self

    ##
    # True if we've warned about PATH not including Gem.bindir

    attr_accessor :path_warning

    # DOC: Missing docs or :nodoc:.
    attr_writer :exec_format

    # Defaults to use Ruby's program prefix and suffix.
    def exec_format
      @exec_format ||= Gem.default_exec_format
    end

  end

  ##
  # Constructs an Installer instance that will install the gem located at
  # +gem+.  +options+ is a Hash with the following keys:
  #
  # :bin_dir:: Where to put a bin wrapper if needed.
  # :development:: Whether or not development dependencies should be installed.
  # :env_shebang:: Use /usr/bin/env in bin wrappers.
  # :force:: Overrides all version checks and security policy checks, except
  #          for a signed-gems-only policy.
  # :format_executable:: Format the executable the same as the ruby executable.
  #                      If your ruby is ruby18, foo_exec will be installed as
  #                      foo_exec18.
  # :ignore_dependencies:: Don't raise if a dependency is missing.
  # :install_dir:: The directory to install the gem into.
  # :security_policy:: Use the specified security policy.  See Gem::Security
  # :user_install:: Indicate that the gem should be unpacked into the users
  #                 personal gem directory.
  # :only_install_dir:: Only validate dependencies against what is in the
  #                     install_dir
  # :wrappers:: Install wrappers if true, symlinks if false.
  # :build_args:: An Array of arguments to pass to the extension builder
  #               process. If not set, then Gem::Command.build_args is used

  def initialize(gem, options={})
    require 'fileutils'

    @gem = gem
    @options = options
    @package = Gem::Package.new @gem

    process_options

    @package.security_policy = @security_policy

    if options[:user_install] and not options[:unpack] then
      @gem_home = Gem.user_dir
      @bin_dir = Gem.bindir gem_home unless options[:bin_dir]
      check_that_user_bin_dir_is_in_path
    end
  end

  ##
  # Checks if +filename+ exists in +@bin_dir+.
  #
  # If +@force+ is set +filename+ is overwritten.
  #
  # If +filename+ exists and is a RubyGems wrapper for different gem the user
  # is consulted.
  #
  # If +filename+ exists and +@bin_dir+ is Gem.default_bindir (/usr/local) the
  # user is consulted.
  #
  # Otherwise +filename+ is overwritten.

  def check_executable_overwrite filename # :nodoc:
    return if @force

    generated_bin = File.join @bin_dir, formatted_program_filename(filename)

    return unless File.exist? generated_bin

    ruby_executable = false
    existing = nil

    open generated_bin, 'rb' do |io|
      next unless io.gets =~ /^#!/ # shebang
      io.gets # blankline

      # TODO detect a specially formatted comment instead of trying
      # to run a regexp against ruby code.
      next unless io.gets =~ /This file was generated by RubyGems/

      ruby_executable = true
      existing = io.read.slice(/^gem (['"])(.*?)(\1),/, 2)
    end

    return if spec.name == existing

    # somebody has written to RubyGems' directory, overwrite, too bad
    return if Gem.default_bindir != @bin_dir and not ruby_executable

    question = "#{spec.name}'s executable \"#{filename}\" conflicts with "

    if ruby_executable then
      question << existing

      return if ask_yes_no "#{question}\nOverwrite the executable?", false

      conflict = "installed executable from #{existing}"
    else
      question << generated_bin

      return if ask_yes_no "#{question}\nOverwrite the executable?", false

      conflict = generated_bin
    end

    raise Gem::InstallError,
      "\"#{filename}\" from #{spec.name} conflicts with #{conflict}"
  end

  ##
  # Lazy accessor for the spec's gem directory.

  def gem_dir
    @gem_dir ||= File.join(gem_home, "gems", spec.full_name)
  end

  ##
  # Lazy accessor for the installer's spec.

  def spec
    @spec ||= @package.spec
  rescue Gem::Package::Error => e
    raise Gem::InstallError, "invalid gem: #{e.message}"
  end

  ##
  # Installs the gem and returns a loaded Gem::Specification for the installed
  # gem.
  #
  # The gem will be installed with the following structure:
  #
  #   @gem_home/
  #     cache/<gem-version>.gem #=> a cached copy of the installed gem
  #     gems/<gem-version>/... #=> extracted files
  #     specifications/<gem-version>.gemspec #=> the Gem::Specification

  def install
    pre_install_checks

    run_pre_install_hooks

    # Completely remove any previous gem files
    FileUtils.rm_rf gem_dir

    FileUtils.mkdir_p gem_dir

    extract_files

    build_extensions
    write_build_info_file
    run_post_build_hooks

    generate_bin
    write_spec
    write_cache_file

    say spec.post_install_message unless spec.post_install_message.nil?

    spec.loaded_from = spec_file

    Gem::Specification.add_spec spec unless Gem::Specification.include? spec

    run_post_install_hooks

    spec

  # TODO This rescue is in the wrong place. What is raising this exception?
  # move this rescue to around the code that actually might raise it.
  rescue Zlib::GzipFile::Error
    raise Gem::InstallError, "gzip error installing #{gem}"
  end

  def run_pre_install_hooks # :nodoc:
    Gem.pre_install_hooks.each do |hook|
      if hook.call(self) == false then
        location = " at #{$1}" if hook.inspect =~ /@(.*:\d+)/

        message = "pre-install hook#{location} failed for #{spec.full_name}"
        raise Gem::InstallError, message
      end
    end
  end

  def run_post_build_hooks # :nodoc:
    Gem.post_build_hooks.each do |hook|
      if hook.call(self) == false then
        FileUtils.rm_rf gem_dir

        location = " at #{$1}" if hook.inspect =~ /@(.*:\d+)/

        message = "post-build hook#{location} failed for #{spec.full_name}"
        raise Gem::InstallError, message
      end
    end
  end

  def run_post_install_hooks # :nodoc:
    Gem.post_install_hooks.each do |hook|
      hook.call self
    end
  end

  ##
  #
  # Return an Array of Specifications contained within the gem_home
  # we'll be installing into.

  def installed_specs
    @specs ||= begin
      specs = []

      Dir[File.join(gem_home, "specifications", "*.gemspec")].each do |path|
        spec = Gem::Specification.load path.untaint
        specs << spec if spec
      end

      specs
    end
  end

  ##
  # Ensure that the dependency is satisfied by the current installation of
  # gem.  If it is not an exception is raised.
  #
  # spec       :: Gem::Specification
  # dependency :: Gem::Dependency

  def ensure_dependency(spec, dependency)
    unless installation_satisfies_dependency? dependency then
      raise Gem::InstallError, "#{spec.name} requires #{dependency}"
    end
    true
  end

  ##
  # True if the gems in the system satisfy +dependency+.

  def installation_satisfies_dependency?(dependency)
    return true if installed_specs.detect { |s| dependency.matches_spec? s }
    return false if @only_install_dir
    not dependency.matching_specs.empty?
  end

  ##
  # Unpacks the gem into the given directory.

  def unpack(directory)
    @gem_dir = directory
    extract_files
  end

  ##
  # The location of of the spec file that is installed.
  #

  def spec_file
    File.join gem_home, "specifications", "#{spec.full_name}.gemspec"
  end

  ##
  # Writes the .gemspec specification (in Ruby) to the gem home's
  # specifications directory.

  def write_spec
    open spec_file, 'w' do |file|
      file.puts spec.to_ruby_for_cache
      file.fsync rescue nil # for filesystems without fsync(2)
    end
  end

  ##
  # Creates windows .bat files for easy running of commands

  def generate_windows_script(filename, bindir)
    if Gem.win_platform? then
      script_name = filename + ".bat"
      script_path = File.join bindir, File.basename(script_name)
      File.open script_path, 'w' do |file|
        file.puts windows_stub_script(bindir, filename)
      end

      say script_path if Gem.configuration.really_verbose
    end
  end

  # DOC: Missing docs or :nodoc:.
  def generate_bin
    return if spec.executables.nil? or spec.executables.empty?

    Dir.mkdir @bin_dir unless File.exist? @bin_dir
    raise Gem::FilePermissionError.new(@bin_dir) unless File.writable? @bin_dir

    spec.executables.each do |filename|
      filename.untaint
      bin_path = File.join gem_dir, spec.bindir, filename

      unless File.exist? bin_path then
        # TODO change this to a more useful warning
        warn "#{bin_path} maybe `gem pristine #{spec.name}` will fix it?"
        next
      end

      mode = File.stat(bin_path).mode | 0111
      FileUtils.chmod mode, bin_path

      check_executable_overwrite filename

      if @wrappers then
        generate_bin_script filename, @bin_dir
      else
        generate_bin_symlink filename, @bin_dir
      end

    end
  end

  ##
  # Creates the scripts to run the applications in the gem.
  #--
  # The Windows script is generated in addition to the regular one due to a
  # bug or misfeature in the Windows shell's pipe.  See
  # http://blade.nagaokaut.ac.jp/cgi-bin/scat.rb/ruby/ruby-talk/193379

  def generate_bin_script(filename, bindir)
    bin_script_path = File.join bindir, formatted_program_filename(filename)

    FileUtils.rm_f bin_script_path # prior install may have been --no-wrappers

    File.open bin_script_path, 'wb', 0755 do |file|
      file.print app_script_text(filename)
    end

    say bin_script_path if Gem.configuration.really_verbose

    generate_windows_script filename, bindir
  end

  ##
  # Creates the symlinks to run the applications in the gem.  Moves
  # the symlink if the gem being installed has a newer version.

  def generate_bin_symlink(filename, bindir)
    if Gem.win_platform? then
      alert_warning "Unable to use symlinks on Windows, installing wrapper"
      generate_bin_script filename, bindir
      return
    end

    src = File.join gem_dir, spec.bindir, filename
    dst = File.join bindir, formatted_program_filename(filename)

    if File.exist? dst then
      if File.symlink? dst then
        link = File.readlink(dst).split File::SEPARATOR
        cur_version = Gem::Version.create(link[-3].sub(/^.*-/, ''))
        return if spec.version < cur_version
      end
      File.unlink dst
    end

    FileUtils.symlink src, dst, :verbose => Gem.configuration.really_verbose
  end

  ##
  # Generates a #! line for +bin_file_name+'s wrapper copying arguments if
  # necessary.
  #
  # If the :custom_shebang config is set, then it is used as a template
  # for how to create the shebang used for to run a gem's executables.
  #
  # The template supports 4 expansions:
  #
  #  $env    the path to the unix env utility
  #  $ruby   the path to the currently running ruby interpreter
  #  $exec   the path to the gem's executable
  #  $name   the name of the gem the executable is for
  #

  def shebang(bin_file_name)
    ruby_name = Gem::ConfigMap[:ruby_install_name] if @env_shebang
    path = File.join gem_dir, spec.bindir, bin_file_name
    first_line = File.open(path, "rb") {|file| file.gets}

    if /\A#!/ =~ first_line then
      # Preserve extra words on shebang line, like "-w".  Thanks RPA.
      shebang = first_line.sub(/\A\#!.*?ruby\S*((\s+\S+)+)/, "#!#{Gem.ruby}")
      opts = $1
      shebang.strip! # Avoid nasty ^M issues.
    end

    if which = Gem.configuration[:custom_shebang]
      # replace bin_file_name with "ruby" to avoid endless loops
      which = which.gsub(/ #{bin_file_name}$/," #{Gem::ConfigMap[:ruby_install_name]}")

      which = which.gsub(/\$(\w+)/) do
        case $1
        when "env"
          @env_path ||= ENV_PATHS.find {|env_path| File.executable? env_path }
        when "ruby"
          "#{Gem.ruby}#{opts}"
        when "exec"
          bin_file_name
        when "name"
          spec.name
        end
      end

      "#!#{which}"
    elsif not ruby_name then
      "#!#{Gem.ruby}#{opts}"
    elsif opts then
      "#!/bin/sh\n'exec' #{ruby_name.dump} '-x' \"$0\" \"$@\"\n#{shebang}"
    else
      # Create a plain shebang line.
      @env_path ||= ENV_PATHS.find {|env_path| File.executable? env_path }
      "#!#{@env_path} #{ruby_name}"
    end
  end

  ##
  # Ensures the Gem::Specification written out for this gem is loadable upon
  # installation.

  def ensure_loadable_spec
    ruby = spec.to_ruby_for_cache
    ruby.untaint

    begin
      eval ruby
    rescue StandardError, SyntaxError => e
      raise Gem::InstallError,
            "The specification for #{spec.full_name} is corrupt (#{e.class})"
    end
  end

  # DOC: Missing docs or :nodoc:.
  def ensure_required_ruby_version_met
    if rrv = spec.required_ruby_version then
      unless rrv.satisfied_by? Gem.ruby_version then
        raise Gem::InstallError, "#{spec.name} requires Ruby version #{rrv}."
      end
    end
  end

  # DOC: Missing docs or :nodoc:.
  def ensure_required_rubygems_version_met
    if rrgv = spec.required_rubygems_version then
      unless rrgv.satisfied_by? Gem.rubygems_version then
        raise Gem::InstallError,
          "#{spec.name} requires RubyGems version #{rrgv}. " +
          "Try 'gem update --system' to update RubyGems itself."
      end
    end
  end

  # DOC: Missing docs or :nodoc:.
  def ensure_dependencies_met
    deps = spec.runtime_dependencies
    deps |= spec.development_dependencies if @development

    deps.each do |dep_gem|
      ensure_dependency spec, dep_gem
    end
  end

  # DOC: Missing docs or :nodoc:.
  def process_options
    @options = {
      :bin_dir      => nil,
      :env_shebang  => false,
      :force        => false,
      :install_dir  => Gem.dir,
      :only_install_dir => false
    }.merge options

    @env_shebang         = options[:env_shebang]
    @force               = options[:force]
    @gem_home            = options[:install_dir]
    @ignore_dependencies = options[:ignore_dependencies]
    @format_executable   = options[:format_executable]
    @security_policy     = options[:security_policy]
    @wrappers            = options[:wrappers]
    @only_install_dir    = options[:only_install_dir]

    # If the user has asked for the gem to be installed in a directory that is
    # the system gem directory, then use the system bin directory, else create
    # (or use) a new bin dir under the gem_home.
    @bin_dir             = options[:bin_dir] || Gem.bindir(gem_home)
    @development         = options[:development]

    @build_args          = options[:build_args] || Gem::Command.build_args
  end

  # DOC: Missing docs or :nodoc:.
  def check_that_user_bin_dir_is_in_path
    user_bin_dir = @bin_dir || Gem.bindir(gem_home)
    user_bin_dir = user_bin_dir.gsub(File::SEPARATOR, File::ALT_SEPARATOR) if
      File::ALT_SEPARATOR

    path = ENV['PATH']
    if Gem.win_platform? then
      path = path.downcase
      user_bin_dir = user_bin_dir.downcase
    end

    unless path.split(File::PATH_SEPARATOR).include? user_bin_dir then
      unless self.class.path_warning then
        alert_warning "You don't have #{user_bin_dir} in your PATH,\n\t  gem executables will not run."
        self.class.path_warning = true
      end
    end
  end

  # DOC: Missing docs or :nodoc:.
  def verify_gem_home(unpack = false)
    FileUtils.mkdir_p gem_home
    raise Gem::FilePermissionError, gem_home unless
      unpack or File.writable?(gem_home)
  end

  ##
  # Return the text for an application file.

  def app_script_text(bin_file_name)
    return <<-TEXT
#{shebang bin_file_name}
#
# This file was generated by RubyGems.
#
# The application '#{spec.name}' is installed as part of a gem, and
# this file is here to facilitate running it.
#

require 'rubygems'

version = "#{Gem::Requirement.default}"

if ARGV.first
  str = ARGV.first
  str = str.dup.force_encoding("BINARY") if str.respond_to? :force_encoding
  if str =~ /\\A_(.*)_\\z/
    version = $1
    ARGV.shift
  end
end

gem '#{spec.name}', version
load Gem.bin_path('#{spec.name}', '#{bin_file_name}', version)
TEXT
  end

  ##
  # return the stub script text used to launch the true ruby script

  def windows_stub_script(bindir, bin_file_name)
    ruby = File.basename(Gem.ruby).chomp('"')
    return <<-TEXT
@ECHO OFF
IF NOT "%~f0" == "~f0" GOTO :WinNT
@"#{ruby}" "#{File.join(bindir, bin_file_name)}" %1 %2 %3 %4 %5 %6 %7 %8 %9
GOTO :EOF
:WinNT
@"#{ruby}" "%~dpn0" %*
TEXT
  end

  ##
  # Builds extensions.  Valid types of extensions are extconf.rb files,
  # configure scripts and rakefiles or mkrf_conf files.

  def build_extensions
    return if spec.extensions.empty?

    if @build_args.empty?
      say "Building native extensions.  This could take a while..."
    else
      say "Building native extensions with: '#{@build_args.join(' ')}'"
      say "This could take a while..."
    end

    dest_path = File.join gem_dir, spec.require_paths.first
    ran_rake = false # only run rake once

    spec.extensions.each do |extension|
      break if ran_rake
      results = []

      extension ||= ""
      extension_dir = File.join gem_dir, File.dirname(extension)

      builder = case extension
                when /extconf/ then
                  Gem::Ext::ExtConfBuilder
                when /configure/ then
                  Gem::Ext::ConfigureBuilder
                when /rakefile/i, /mkrf_conf/i then
                  ran_rake = true
                  Gem::Ext::RakeBuilder
                when /CMakeLists.txt/ then
                  Gem::Ext::CmakeBuilder
                else
                  message = "No builder for extension '#{extension}'"
                  extension_build_error extension_dir, message
                end

      begin
        FileUtils.mkdir_p dest_path

        Dir.chdir extension_dir do
          results = builder.build(extension, gem_dir, dest_path,
                                  results, @build_args)

          say results.join("\n") if Gem.configuration.really_verbose
        end
      rescue
        extension_build_error(extension_dir, results.join("\n"), $@)
      end
    end
  end

  ##
  # Logs the build +output+ in +build_dir+, then raises ExtensionBuildError.

  def extension_build_error(build_dir, output, backtrace = nil)
    gem_make_out = File.join build_dir, 'gem_make.out'

    open gem_make_out, 'wb' do |io| io.puts output end

    message = <<-EOF
ERROR: Failed to build gem native extension.

    #{output}

Gem files will remain installed in #{gem_dir} for inspection.
Results logged to #{gem_make_out}
EOF

    raise ExtensionBuildError, message, backtrace
  end

  ##
  # Reads the file index and extracts each file into the gem directory.
  #
  # Ensures that files can't be installed outside the gem directory.

  def extract_files
    @package.extract_files gem_dir
  end

  ##
  # Prefix and suffix the program filename the same as ruby.

  def formatted_program_filename(filename)
    if @format_executable then
      self.class.exec_format % File.basename(filename)
    else
      filename
    end
  end

  ##
  #
  # Return the target directory where the gem is to be installed. This
  # directory is not guaranteed to be populated.
  #

  def dir
    gem_dir.to_s
  end

  ##
  # Performs various checks before installing the gem such as the install
  # repository is writable and its directories exist, required ruby and
  # rubygems versions are met and that dependencies are installed.
  #
  # Version and dependency checks are skipped if this install is forced.
  #
  # The dependent check will be skipped this install is ignoring dependencies.

  def pre_install_checks
    verify_gem_home options[:unpack]

    # If we're forcing the install then disable security unless the security
    # policy says that we only install signed gems.
    @security_policy = nil if
      @force and @security_policy and not @security_policy.only_signed

    ensure_loadable_spec

    Gem.ensure_gem_subdirectories gem_home

    return true if @force

    ensure_required_ruby_version_met
    ensure_required_rubygems_version_met
    ensure_dependencies_met unless @ignore_dependencies

    true
  end

  ##
  # Writes the file containing the arguments for building this gem's
  # extensions.

  def write_build_info_file
    return if @build_args.empty?

    build_info_dir = File.join gem_home, 'build_info'

    FileUtils.mkdir_p build_info_dir

    build_info_file = File.join build_info_dir, "#{spec.full_name}.info"

    open build_info_file, 'w' do |io|
      @build_args.each do |arg|
        io.puts arg
      end
    end
  end

  ##
  # Writes the .gem file to the cache directory

  def write_cache_file
    cache_file = File.join gem_home, 'cache', spec.file_name

    FileUtils.cp @gem, cache_file unless File.exist? cache_file
  end

end

