require 'rubygems/command'
require 'rubygems/command_aids'
require 'rubygems/doc_manager'
require 'rubygems/install_update_options'
require 'rubygems/installer'
require 'rubygems/local_remote_options'
require 'rubygems/remote_installer'
require 'rubygems/validator'
require 'rubygems/version_option'

class Gem::Commands::InstallCommand < Gem::Command
  include Gem::CommandAids
  include Gem::VersionOption
  include Gem::LocalRemoteOptions
  include Gem::InstallUpdateOptions

  def initialize
    super(
          'install',
          'Install a gem into the local repository',
          {
      :domain => :both,
      :generate_rdoc => true,
      :generate_ri   => true,
      :force => false,
      :test => false,
      :wrappers => true,
      :version => Gem::Requirement.default,
      :install_dir => Gem.dir,
      :security_policy => nil,
    })
    add_version_option('install')
    add_local_remote_options
    add_install_update_options
  end

  def usage
    "#{program_name} GEMNAME [options]
 or: #{program_name} GEMNAME [options] -- --build-flags"
  end

  def arguments
    "GEMNAME   name of gem to install"
  end

  def defaults_str
    "--both --version '#{Gem::Requirement.default}' --rdoc --ri --no-force\n" \
    "--no-test --install-dir #{Gem.dir}"
  end

  def execute
    ENV['GEM_PATH'] = options[:install_dir]

    gems = get_all_gem_names.each do |gem_name|
      if local? then
        begin
          entries = []
          if File.exist?(gem_name) and not File.directory?(gem_name)
            entries << gem_name
          else
            filepattern = gem_name + "*.gem"
            entries = Dir[filepattern]
          end

          unless entries.size > 0 then
            if options[:domain] == :local then
              alert_error "Local gem file not found: #{filepattern}"
            end
          else
            installer = Gem::Installer.new entries.last, options
            result = installer.install options[:force], options[:install_dir]

            installed_gems = [result].flatten
            say "Successfully installed #{installed_gems[0].full_name}" if
              installed_gems
          end
        rescue Gem::LocalInstallationError => e
          say " -> Local installation can't proceed: #{e.message}"
        rescue Gem::LoadError => e
          say " -> Local installation can't proceed due to LoadError: #{e.message}"
        rescue Gem::InstallError => e
          raise "Error instaling #{gem_name}:\n\t#{e.message}"
        rescue => e
          # TODO: Fix this handle to allow the error to propagate to
          # the top level handler.  Examine the other errors as
          # well.  This implementation here looks suspicious to me --
          # JimWeirich (4/Jan/05)
          alert_error "Error installing gem #{gem_name}[.gem]: #{e.message}"
          return
        end
      end

      if remote? && installed_gems.nil?
        installer = Gem::RemoteInstaller.new(options)
        installed_gems = installer.install(gem_name, options[:version],
                                           options[:force],
                                           options[:install_dir])
        if installed_gems then
          installed_gems.compact!
          installed_gems.each do |spec|
            say "Successfully installed #{spec.full_name}"
          end
        end
      end

      unless installed_gems then
        alert_error "Could not install a local or remote copy of the gem: #{gem_name}"
        terminate_interaction 1
      end

      # NOTE: *All* of the RI documents must be generated first.
      # For some reason, RI docs cannot be generated after any RDoc
      # documents are generated.

      if options[:generate_ri]
        installed_gems.each do |gem|
          Gem::DocManager.new(gem, options[:rdoc_args]).generate_ri
        end
      end

      if options[:generate_rdoc]
        installed_gems.each do |gem|
          Gem::DocManager.new(gem, options[:rdoc_args]).generate_rdoc
        end
      end

      if options[:test]
        installed_gems.each do |spec|
          gem_spec = Gem::SourceIndex.from_installed_gems.search(spec.name, spec.version.version).first
          result = Gem::Validator.new.unit_test(gem_spec)
          if result and not result.passed?
            unless ask_yes_no("...keep Gem?", true) then
              Gem::Uninstaller.new(spec.name, :version => spec.version.version).uninstall
            end
          end
        end
      end
    end
  end

end

