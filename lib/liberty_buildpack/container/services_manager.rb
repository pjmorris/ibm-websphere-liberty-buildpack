# Encoding: utf-8
# IBM WebSphere Application Server Liberty Buildpack
# Copyright 2013 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'rexml/document'
require 'yaml'
require 'fileutils'
require 'set'
require 'liberty_buildpack/container'
require 'liberty_buildpack/container/install_components'
require 'liberty_buildpack/util/constantize'
require 'liberty_buildpack/util/application_cache'
require 'liberty_buildpack/util/format_duration'
require 'liberty_buildpack/diagnostics/logger_factory'

module LibertyBuildpack::Container
  # The class that encapsulate access to services and services information.
  class ServicesManager

    def initialize(vcap_services, server_dir, opt_out_string)
      @logger = LibertyBuildpack::Diagnostics::LoggerFactory.get_logger
      @logger.debug("init: server dir is #{server_dir}, vcap_services is #{vcap_services} and opt_out is #{opt_out_string}")
      @opt_out = parse_opt_out(opt_out_string)
      FileUtils.mkdir_p(server_dir)
      # The collection of service instances that require full autoconfig
      @services_full_autoconfig = []
      # The collection of services that have opted out of autoconfig config updates only. Supporting software still needs to be installed.
      @services_no_xml_updates = []
      # The collection of services that have opted out of all autoconfig.
      @services_no_autoconfig = []
      @config = load_services_config
      # count of service instances by xml stanza type. For example, MySql and DB2 would be the same xml stanza type because both use the dataSource xml stanza.
      @service_type_instances = {}
      parse_vcap_services(vcap_services, server_dir)
    end

    #-----------------------------------------------------------------------------------
    # return true if any service requires Liberty extensions to be installed
    #-----------------------------------------------------------------------------------
    def requires_liberty_extensions?
      @services_full_autoconfig.each do |service|
        return true if service[INSTANCE].requires_liberty_extensions?
      end
      @services_no_xml_updates.each do |service|
        return true if service[INSTANCE].requires_liberty_extensions?
      end
      false
    end

    # ------------------------------------------------------
    # Get the list of Liberty features required by the bound services
    #
    # @return [Set<String>] A set containing the features
    #-------------------------------------------------------
    def get_required_features
      features = Set.new
      @services_full_autoconfig.each do |service|
        service[INSTANCE].get_required_features(features)
      end
      @services_no_xml_updates.each do |service|
        service[INSTANCE].get_required_features(features)
      end
      features
    end

    #---------------------------------------------------------
    # Install any client driver jars required by the bound services
    #
    # @param uris - the hash of available uris from the repository
    # @param server_dir - the server directory where server.xml is located
    #---------------------------------------------------------
    def install_client_jars(uris, server_dir)
      @logger.debug("uris #{uris}, #{server_dir}")
      lib_dir = File.join(server_dir, 'lib')
      # make sure lib_dir exists.
      FileUtils.mkdir_p(lib_dir)
      existing_jars = Dir[File.join(lib_dir, '*.jar')]
      @logger.debug("existing jars #{existing_jars}")
      to_install = get_urls_for_client_jars(existing_jars, uris)
      Dir.mktmpdir do |root|
        to_install.each do |uri|
          install_jar(root, lib_dir, uri)
        end
      end
    end

    #-------------------------------------------
    # Get required components (prereq zips and esas) from services
    #
    # @param uris - the hash containing the <key, uri> information from the repository
    # @param components - the non-null RequiredComponents to update.
    #---------------------------------------------
    def get_required_esas(uris, components)
      @services_full_autoconfig.each do |service|
        service[INSTANCE].get_required_esas(uris, components)
      end
      @services_no_xml_updates.each do |service|
        service[INSTANCE].get_required_esas(uris, components)
      end
    end

    #-------------------------------
    # Update configuration (server.xml, bootstrap.properties, jvm.options)
    #
    # @param document - the REXML::Document for server.xml
    # @param create - true if create, false if update
    # @param server_dir - the server directory where server.xml physically resides
    #-------------------------------
    def update_configuration(document, create, server_dir)
      lib_dir = File.join(server_dir, 'lib')
      driver_jars = Dir[File.join(lib_dir, '*.jar')]
      driver_dir = '${server.config.dir}/lib'
      @services_full_autoconfig.each do |service|
        begin
          if create
            service[INSTANCE].create(document.root, server_dir, driver_dir, driver_jars)
          else
            service[INSTANCE].update(document.root, server_dir, driver_dir, driver_jars, get_number_instances(service[CONFIG]))
          end
        rescue => e
          @logger.warn("Failed to update the configuration for a service. Details are  #{e.message}")
        end
      end
    end

    private

    SERVICES_CONFIG_DIR = '../services/config/'.freeze
    CONFIG = 'config'.freeze
    INSTANCE = 'instance'.freeze
    XML_STANZA_TYPE = 'server_xml_stanza'.freeze

    #-----------------------------------------------
    # Parse the opt-out string and return a hash of <service,opt_out_level>
    #
    # @param string - the opt-out string specified in the environment
    # @return a non-null Hash
    #----------------------------------------------
    def parse_opt_out(string)
      @logger.debug("Opt-out string is #{string}")
      retval = {}
      return retval if string.nil?
      # The opt-out string may contain multiple entries of form service-level with entries separated by white space.
      parts = string.split
      @logger.debug("opt-out string after split is #{parts}")
      parts.each { |part|  process_opt_out(part, retval) }
      retval
    end

    #-----------------------------------------------------
    # Process the opt-out string for a single service type
    #
    # @param string - the opt-out string for a service type
    # @param hash - the Hash to store the processed and verified entries
    #----------------------------------------------------
    def process_opt_out(string, hash)
      # we expect the string to have form of service_name=option. Extract the service name and option. Service name may contain any chars, including an =.
      return if string.nil?
      parts = string.split('=')
      if parts.length < 2
        @logger.warn("Service autoconfig opt out specification #{string} is not a legal opt-out specification. Either the specification does not contain an = or it contains disallowed white space. The opt-out request will be ignored.")
        return
      end
      # Under normal circumstances, the service name will not contain an  = and parts will be length 2. if the service name contained an =, the service name will have been
      # split and will need to be reassembled from the parts. The following handles both cases.
      service = parts[0...(parts.length - 1)].join('=')
      if service.empty?
        @logger.warn("Service autoconfig opt out specification #{string} is not a legal opt-out specification. The service name appears to be missing. The opt-out request will be ignored.")
        return
      end
      spec = parts[-1]
      if spec.casecmp('all') == 0
        hash[service] = 'all'
        @logger.info("opting out of all auto-configuration for service #{service}")
      elsif spec.casecmp('config') == 0
        hash[service] = 'config'
        @logger.info("opting out of auto-configuration configuration updates for service #{service}")
      else
        @logger.warn("#{string} is not a legal opt-out specification for service #{service}. The opt-out request will be ignored and the service will be configured normally.")
      end
    end

    #-----------------------------------------------
    # Load service plugins by reading the yaml files
    #-----------------------------------------------
    def load_services_config
      config = {}
      # Get the directory where the service yml files are located, read file names then load files and update the config hash.
      services_config_path = File.expand_path(SERVICES_CONFIG_DIR, File.dirname(__FILE__))
      Dir.glob("#{services_config_path}/*.yml").each do |file|
        key = File.basename(file, '.yml')
        @logger.debug("loading service config for #{key} from #{file}")
        config[key] = File.open(file, 'r:utf-8') { |yf| YAML.load(yf) }
      end
      @logger.debug("config is #{config}")
      config
    end

    #-------------------------------------------------
    # Parse the VCAP_SERVICES string and generate the cloud variable in runtime_vars.xml
    # Note: this method will always create the runtime-vars.xml file, even if no services are bound.
    #
    # @param  vcap_services - the hash containing parsed VCAP_SERVICES
    # @param server_dir - the name of the directory where the runtime_vars.xml file should be created
    #-------------------------------------------------
    def parse_vcap_services(vcap_services, server_dir)
      # runtime_vars will not exist, we must ensure it's created in this method
      runtime_vars_doc = REXML::Document.new('<server></server>')
      unless vcap_services.nil?
        vcap_services.each do |service_type, service_data|
          @logger.debug("processing service type #{service_type} and data #{service_data}")
          process_service_type(runtime_vars_doc.root, service_type, service_data)
        end
      end
      runtime_vars = File.join(server_dir, 'runtime-vars.xml')
      formatter = REXML::Formatters::Pretty.new(2)
      formatter.compact = true
      File.open(runtime_vars, 'w:utf-8') { |file| formatter.write(runtime_vars_doc, file) }
      @logger.debug("runtime-vars file is #{runtime_vars}")
      @logger.debug("runtime vars contents is #{File.readlines(runtime_vars)}")
    end

    #------------------------------------------------------
    # Process all instances of a given service type. For each instance, write the cloud variables to runtime_vars.xml, create the object
    # representing the service instance and store it into the appropriate services array
    #
    # @param element - the REXML root element for runtime_vars.xml
    # @param service_type - the String type as read from VCAP_SERVICES
    # @param service_data - the array holding the instances data
    #------------------------------------------------------
    def process_service_type(element, service_type, service_data)
      # all instances of a given type share the same config data. We have a default type for services that don't have a plugin.
      type = get_service_type(service_type)
      config = @config[type]
      xml_element = config[XML_STANZA_TYPE]
      if xml_element.nil?
        xml_element = 'none'
        @logger.warn("The configuration file for service type #{type} is missing the required server_xml_stanza element")
      end
      target_array = find_autoconfig_option(service_type)
      @logger.debug("processing service instances of type #{type}. Config is #{config}")
      service_data.each do |instance|
        service_instance = create_instance(element, type, config, instance)
        unless service_instance.nil?
          instance_hash = { INSTANCE => service_instance, CONFIG => config }
          target_array.push(instance_hash)
          if @service_type_instances[xml_element].nil?
            @service_type_instances[xml_element] = 1
          else
            @service_type_instances[xml_element] = @service_type_instances[xml_element] + 1
          end
        end
      end
    end

    #-----------------------------------
    # find the service type using the vcap_services name
    #-----------------------------------
    def get_service_type(name)
      candidates =  []
      @config.each_key { |key| candidates.push(key) if name.include?(key) }
      return 'default' if candidates.empty?
      return candidates[0] if candidates.length == 1
      # Services typically have a name+version. Plugin yml file names are the name, without the version. Suppose I have two services named monitor-1.0 and appmonitor-2.0
      # and plugin providers have followed conventions. type appmonitor will not match monitor, but monitor will match both appmonitor and monitor. Choose shorter
      current = candidate[0]
      length = current.length
      candidates[1..(candidates.length - 1)].each do |candidate|
        if candidate.length < length
          current = candidate
          length = current.length
        end
      end
      current
    end

    #-------------------------------------
    # Determine the autoconfig level for a given service type
    #
    # @param service_type - the service type
    # @return the array instance where service instances of the type are cached
    #-------------------------------------
    def find_autoconfig_option(service_type)
      option = @opt_out[service_type]
      return @services_full_autoconfig if option.nil?
      return @services_no_xml_updates if option == 'config'
      @services_no_autoconfig
    end
    #------------------------------------------------
    # Create a service instance
    #
    # @param element - the REXML root element for the runtime-vars.xml document
    # @param type - the service type
    # @param config - the hash containing the config for the service type
    # @param instance_data - the hash containing the service instance data from vcap_services
    #-------------------------------------------------
    def create_instance(element, type, config, instance_data)
      file = config['class_file']
      if file.nil?
        @logger.warn("required configuration attribute class_file missing for service type #{type}. This type cannot be processed")
        return
      end
      class_name = config['class_name']
      if class_name.nil?
        @logger.warn("required configuration attribute class_name missing for service type #{type}. This type cannot be processed")
        return
      end
      @logger.debug("creating service instance #{type}, #{file}, #{class_name}")
      # require the file
      filename = File.join(File.expand_path('..', File.dirname(__FILE__)), 'services', file)
      require filename
      instance = class_name.constantize.new(type, config)
      instance.parse_vcap_services(element, instance_data)
      instance
    end

    #-------------------------------------------
    # Determine the number of instances of a given xml type. Instances of an xml type modify the same configuration stanzas
    # in server.xml. For example, DB2 and MySql are both "dataSource" xml types, even though they are different service types.
    #
    # @param config [Hash] - the config hash for a service instance.
    #------------------------------------------
    def get_number_instances(config)
      type = config[XML_STANZA_TYPE]
      @service_type_instances[type]
    end

    #-------------------------------------------
    # Determine the list of client driver jar urls that need to be downloaded.
    #
    # @param existing - a non-null array containing the names of jar files that are already installed.
    # @param urls - a non-null array of available download urls.
    # return a non-null, but possibly empty, array containing the urls that need to be downloaded.
    #---------------------------------------------
    def get_urls_for_client_jars(existing, urls)
      jar_urls = Set.new
      @services_full_autoconfig.each do |service|
        needed = service[INSTANCE].get_urls_for_client_jars(existing, urls)
        jar_urls.merge(needed) unless needed.nil?
      end
      @services_no_xml_updates.each do |service|
        needed = service[INSTANCE].get_urls_for_client_jars(existing, urls)
        jar_urls.merge(needed) unless needed.nil?
      end
      required = jar_urls.to_a
      @logger.debug("required client jars #{required}")
      required
    end

    #-----------------------------------------------------
    # worker method to download/install jars from a specific uri
    #
    # @param root - temp working dir for unzip operations
    # @param lib_dir - directory where jars will be installed to
    # @param uri - the uri to process
    #----------------------------------------------------
    def install_jar(root, lib_dir, uri)
      download_start_time = Time.now
      print "-----> Installing client jar(s) from #{uri} "
      LibertyBuildpack::Util::ApplicationCache.new.get(uri) do |file|
        if file.path.end_with?('zip.cached')
          system "unzip -oq -d #{root} #{file.path} 2>&1"
          Dir.glob("#{root}/**/*.jar").each do |file2|
            system "mv #{file2} #{lib_dir}"
          end
        elsif file.path.end_with?('jar.cached') || file.path.end_with?('rar.cached')
          # extracting the jar name is a real pain. things like File.basepath don't work
          n_one = File.basename(file.path, '.cached')
          name = n_one.split('%2F')[-1]
          @logger.debug("jar copy command is cp #{file.path} #{File.join(lib_dir, name)}")
          FileUtils.copy_file(file.path, File.join(lib_dir, name))
        end # end if
      end # end do |file|
      puts "(#{(Time.now - download_start_time).duration})"
    end
  end  # class
end
