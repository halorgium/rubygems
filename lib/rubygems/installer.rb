#--
# Copyright 2006 by Chad Fowler, Rich Kilmer, Jim Weirich and others.
# All rights reserved.
# See LICENSE.txt for permissions.
#++

require 'fileutils'
require 'pathname'
require 'rbconfig'

require 'rubygems/format'
require 'rubygems/dependency_list'
require 'rubygems/ext'

##
# The installer class processes RubyGem .gem files and installs the
# files contained in the .gem into the Gem.path.
#
class Gem::Installer

  ##
  # Raised when there is an error while building extensions.
  #
  class ExtensionBuildError < Gem::InstallError; end

  include Gem::UserInteraction

  ##
  # Constructs an Installer instance
  #
  # gem:: [String] The file name of the gem
  #
  def initialize(gem, options={})
    @gem = gem
    @options = options
  end

  ##
  # Installs the gem in the Gem.path.  This will fail (unless
  # force=true) if a Gem has a requirement on another Gem that is
  # not installed.  The installation will install in the following
  # structure:
  #
  #  Gem.path/
  #      specifications/<gem-version>.gemspec #=> the extracted YAML gemspec
  #      gems/<gem-version>/... #=> the extracted Gem files
  #      cache/<gem-version>.gem #=> a cached copy of the installed Gem
  #
  # force:: [default = false] if false will fail if a required Gem is not
  #         installed, or if the Ruby version is too low for the gem
  # install_dir:: [default = Gem.dir] directory that Gem is to be installed in
  #
  # return:: [Gem::Specification] The specification for the newly installed
  #          Gem.
  #
  def install(force=false, install_dir=Gem.dir, ignore_this_parameter=false)
    # if we're forcing the install, then disable security, _unless_
    # the security policy says that we only install singed gems
    # (this includes Gem::Security::HighSecurity)
    security_policy = @options[:security_policy]
    security_policy = nil if force && security_policy && security_policy.only_signed != true

    begin
      format = Gem::Format.from_file_by_path @gem, security_policy
    rescue Gem::Package::FormatError
      raise Gem::InstallError, "invalid gem format for #{@gem}"
    end

    unless force
      spec = format.spec

      if rrv = spec.required_ruby_version then
        unless rrv.satisfied_by? Gem::Version.new(RUBY_VERSION) then
          raise Gem::InstallError, "#{spec.name} requires Ruby version #{rrv}"
        end
      end

      if rrgv = spec.required_rubygems_version then
        unless rrgv.satisfied_by? Gem::Version.new(Gem::RubyGemsVersion) then
          raise Gem::InstallError,
                "#{spec.name} requires RubyGems version #{rrgv}"
        end
      end

      unless @options[:ignore_dependencies] then
        spec.dependencies.each do |dep_gem|
          ensure_dependency!(spec, dep_gem)
        end
      end
    end

    raise Gem::FilePermissionError, Pathname.new(install_dir).expand_path unless
      File.writable?(install_dir)

    # Build spec dir.
    @directory = File.join(install_dir, "gems", format.spec.full_name).untaint
    FileUtils.mkdir_p @directory

    extract_files(@directory, format)
    generate_bin(format.spec, install_dir)
    build_extensions(@directory, format.spec)

    # Build spec/cache/doc dir.
    Gem.ensure_gem_subdirectories install_dir

    # Write the spec and cache files.
    write_spec(format.spec, File.join(install_dir, "specifications"))
    unless File.exist? File.join(install_dir, "cache", @gem.split(/\//).pop) then
      FileUtils.cp @gem, File.join(install_dir, "cache")
    end

    say format.spec.post_install_message unless
      format.spec.post_install_message.nil?

    format.spec.loaded_from = File.join(install_dir, 'specifications', format.spec.full_name+".gemspec")

    return format.spec
  rescue Zlib::GzipFile::Error
    raise Gem::InstallError, "gzip error installing #{@gem}"
  end

  ##
  # Ensure that the dependency is satisfied by the current
  # installation of gem.  If it is not, then fail (i.e. throw and
  # exception).
  #
  # spec       :: Gem::Specification
  # dependency :: Gem::Dependency
  def ensure_dependency!(spec, dependency)
    raise Gem::InstallError, "#{spec.name} requires #{dependency.name} #{dependency.version_requirements} " unless
      installation_satisfies_dependency?(dependency)
  end

  ##
  # True if the current installed gems satisfy the given dependency.
  #
  # dependency :: Gem::Dependency
  def installation_satisfies_dependency?(dependency)
    current_index = Gem::SourceIndex.from_installed_gems
    current_index.find_name(dependency.name, dependency.version_requirements).size > 0
  end

  ##
  # Unpacks the gem into the given directory.
  #
  def unpack(directory)
    format = Gem::Format.from_file_by_path(@gem, @options[:security_policy])
    extract_files(directory, format)
  end

  ##
  # Writes the .gemspec specification (in Ruby) to the supplied
  # spec_path.
  #
  # spec:: [Gem::Specification] The Gem specification to output
  # spec_path:: [String] The location (path) to write the gemspec to
  #
  def write_spec(spec, spec_path)
    rubycode = spec.to_ruby
    file_name = File.join(spec_path, spec.full_name+".gemspec").untaint
    File.open(file_name, "w") do |file|
      file.puts rubycode
    end
  end

  ##
  # Creates windows .cmd files for easy running of commands
  #
  def generate_windows_script(bindir, filename)
    if Config::CONFIG["arch"] =~ /dos|win32/i
      script_name = filename + ".cmd"
      File.open(File.join(bindir, File.basename(script_name)), "w") do |file|
        file.puts "@#{Gem.ruby} \"#{File.join(bindir,filename)}\" %*"
      end
    end
  end

  def generate_bin(spec, install_dir=Gem.dir)
    return unless spec.executables && ! spec.executables.empty?

    # If the user has asked for the gem to be installed in
    # a directory that is the system gem directory, then
    # use the system bin directory, else create (or use) a
    # new bin dir under the install_dir.
    bindir = Gem.bindir(install_dir)

    Dir.mkdir bindir unless File.exist? bindir
    raise Gem::FilePermissionError.new(bindir) unless File.writable?(bindir)

    spec.executables.each do |filename|
      bin_path = File.join @directory, 'bin', filename
      mode = File.stat(bin_path).mode | 0111
      File.chmod mode, bin_path

      if @options[:wrappers] then
        generate_bin_script spec, filename, bindir, install_dir
      else
        generate_bin_symlink spec, filename, bindir, install_dir
      end
    end
  end

  ##
  # Creates the scripts to run the applications in the gem.
  #--
  # The Windows script is generated in addition to the regular one due to a
  # bug or misfeature in the Windows shell's pipe.  See
  # http://blade.nagaokaut.ac.jp/cgi-bin/scat.rb/ruby/ruby-talk/193379
  #
  def generate_bin_script(spec, filename, bindir, install_dir)
    File.open(File.join(bindir, File.basename(filename)), "w", 0755) do |file|
      file.print app_script_text(spec, install_dir, filename)
    end
    generate_windows_script bindir, filename
  end

  ##
  # Creates the symlinks to run the applications in the gem.  Moves
  # the symlink if the gem being installed has a newer version.
  #
  def generate_bin_symlink(spec, filename, bindir, install_dir)
    if Config::CONFIG["arch"] =~ /dos|win32/i then
      alert_warning "Unable to use symlinks on win32, installing wrapper"
      generate_bin_script spec, filename, bindir, install_dir
      return
    end

    src = File.join @directory, 'bin', filename
    dst = File.join bindir, File.basename(filename)

    if File.exist? dst then
      if File.symlink? dst then
        link = File.readlink(dst).split File::SEPARATOR
        cur_version = Gem::Version.create(link[-3].sub(/^.*-/, ''))
        return if spec.version < cur_version
      end
      File.unlink dst
    end

    File.symlink src, dst
  end

  def shebang(spec, install_dir, bin_file_name)
    if @options[:env_shebang]
      shebang_env
    else
      shebang_default(spec, install_dir, bin_file_name)
    end
  end

  def shebang_default(spec, install_dir, bin_file_name)
    path = File.join(install_dir, "gems", spec.full_name, spec.bindir, bin_file_name)
    File.open(path, "rb") do |file|
      first_line = file.readlines("\n").first 
      path_to_ruby = File.join(Config::CONFIG['bindir'], Config::CONFIG['ruby_install_name'])
      if first_line =~ /^#!/
        # Preserve extra words on shebang line, like "-w".  Thanks RPA.
        shebang = first_line.sub(/\A\#!\s*\S*ruby\S*/, "#!" + path_to_ruby)
      else
        # Create a plain shebang line.
        shebang = "#!" + path_to_ruby
      end
      return shebang.strip  # Avoid nasty ^M issues.
    end
  end

  def shebang_env
    return "#!/usr/bin/env ruby"
  end

  # Return the text for an application file.
  def app_script_text(spec, install_dir, filename)
    text = <<-TEXT
#{shebang(spec, install_dir, filename)}
#
# This file was generated by RubyGems.
#
# The application '#{spec.name}' is installed as part of a gem, and
# this file is here to facilitate running it.
#

require 'rubygems'
version = "> 0"
if ARGV.first =~ /^_(.*)_$/ and Gem::Version.correct? $1 then
version = $1
ARGV.shift
end
gem '#{spec.name}', version
load '#{filename}'
TEXT
    text
  end

  def build_extensions(directory, spec)
    return unless spec.extensions.size > 0
    say "Building native extensions.  This could take a while..."
    start_dir = Dir.pwd
    dest_path = File.join(directory, spec.require_paths[0])
    ran_rake = false # only run rake once

    spec.extensions.each do |extension|
      break if ran_rake
      results = []

      case extension
      when /extconf/ then
        builder = Gem::Ext::ExtConfBuilder
      when /configure/ then
        builder = Gem::Ext::ConfigureBuilder
      when /rakefile/i, /mkrf_conf/i then
        builder = Gem::Ext::RakeBuilder
        ran_rake = true
      else
        builder = nil
        results = ["No builder for extension '#{extension}'"]
      end

      begin
        Dir.chdir File.join(directory, File.dirname(extension))
        results = builder.build(extension, directory, dest_path, results)
      rescue => ex
        results = results.join "\n"

        File.open('gem_make.out', 'wb') { |f| f.puts results }

        message = <<-EOF
ERROR: Failed to build gem native extension.

#{results}

Gem files will remain installed in #{directory} for inspection.
Results logged to #{File.join(Dir.pwd, 'gem_make.out')}
        EOF

        raise ExtensionBuildError, message
      ensure
        Dir.chdir start_dir
      end
    end
  end

  ##
  # Reads the YAML file index and then extracts each file
  # into the supplied directory, building directories for the
  # extracted files as needed.
  #
  # directory:: [String] The root directory to extract files into
  # file:: [IO] The IO that contains the file data
  #
  def extract_files(directory, format)
    directory = expand_and_validate(directory)
    raise ArgumentError, "format required to extract from" if format.nil?

    format.file_entries.each do |entry, file_data|
      path = entry['path'].untaint
      if path =~ /\A\// then # for extra sanity
        raise Gem::InstallError,
              "attempt to install file into #{entry['path'].inspect}"
      end
      path = File.expand_path File.join(directory, path)
      if path !~ /\A#{Regexp.escape directory}/ then
        msg = "attempt to install file into %p under %p" %
                [entry['path'], directory]
        raise Gem::InstallError, msg
      end
      FileUtils.mkdir_p File.dirname(path)
      File.open(path, "wb") do |out|
        out.write file_data
      end
    end
  end

  private

  def expand_and_validate(directory)
    directory = Pathname.new(directory).expand_path
    unless directory.absolute? then
      raise ArgumentError, "install directory %p not absolute" % directory
    end
    directory.to_str
  end

end

