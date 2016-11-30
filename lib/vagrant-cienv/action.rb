require "pathname"
require 'json'
require 'yaml'

require "vagrant/action/builder"

module VagrantPlugins
  module Cienv
    module Action
      # Include the built-in modules so we can use them as top-level things.
      include Vagrant::Action::Builtin

      def self.action_init
        Vagrant::Action::Builder.new.tap do |b|
          b.use InitEnvironment
        end
      end

      # The autoload farm
      action_root = Pathname.new(File.expand_path("../action", __FILE__))
      autoload :InitEnvironment, action_root.join("init_environment")

      class BuildVagrantfile
        def initialize(app, env)
          @app = app
          environment = env[:env]
          root_path = environment.instance_variable_get(:@cwd)
          local_data_path = root_path.join(Vagrant::Environment::DEFAULT_LOCAL_DATA)

          # Only make all the magic if the .qi.yml definition file is found
          return if !File.exist?(root_path.join(".qi.yml"))

          require_relative local_data_path.to_s + "/provision-ci/lib/config_provider.rb"
          require_relative local_data_path.to_s + "/provision-ci/lib/config_provision.rb"
          require_relative local_data_path.to_s + "/provision-ci/lib/config_network.rb"
          require_relative local_data_path.to_s + "/provision-ci/lib/config_folders.rb"

          $vagrant_vmenv_path = local_data_path.to_s + "/provision-ci/"

          # load the .qi.yml file
          qi_file = File.expand_path (root_path.join(".qi.yml"))
          if File.exists?(qi_file)
            qi_definition = YAML.load(File.read(qi_file))
          else
            raise ".qi.yml file not found in this repository"
          end

          # load the environment based on "env_runtime" variable of .qi.yml
          vagrant_env = qi_definition["env_runtime"] || "default"
          environment_file = File.expand_path(local_data_path.to_s + "/provision-ci/envs", File.dirname(__FILE__)) +
                             File::SEPARATOR + vagrant_env
          if File.exists?(environment_file + ".json")
            environment_ci = JSON.parse(File.read(environment_file + ".json"))
          elsif File.exists?(environment_file + ".yml")
            environment_ci = YAML.load(File.read(environment_file + ".yml"))
          else
            raise "Environment_ci config file not found, see envs directory\n #{environment_file}"
          end

          # build the host list of the VMs used, very useful to allow the communication
          # between them based on the hostname and IP stored in the hosts file
          build_hosts_list(environment_ci["vms"])


          vagrantfile_proc = Proc.new do
            Vagrant.configure(2) do |config|

              environment_ci["vms"].each do |vm_id, vm_config|

                config.vm.define vm_id, autostart: vm_config["autostart"] do |instance|

                  # Ansible handles this task better than Vagrant
                  #instance.vm.hostname = vm_id

                  config_provider(instance, vm_config, environment_ci["global"])

                  config_provision(instance, vm_config, vm_id, qi_definition["apps"])

                  config_network(instance, vm_config)

                  config_folders(instance, vm_id, qi_definition["apps"])

                end
              end
            end 
          end

          # The Environment instance has been instantiated without a Vagrantfile
          # that means that we need to store some internal variables and 
          # instantiate again the Vagrantfile instance with our previous code.

          environment.instance_variable_set(:@root_path, root_path)
          environment.instance_variable_set(:@local_data_path, local_data_path) 

          # the cienv code will be the first item to check in the list of
          # Vagrantfile sources
          config_loader = environment.config_loader
          config_loader.set(:cienv, vagrantfile_proc.call)
          environment.instance_variable_set(:@vagrantfile, Vagrant::Vagrantfile.new(config_loader, [:cienv, :home, :root]))
          
        end
        def call(env)
          @app.call(env)
        end
      end
    end
  end
end
