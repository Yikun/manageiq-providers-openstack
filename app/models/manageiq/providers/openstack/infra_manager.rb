class ManageIQ::Providers::Openstack::InfraManager < ManageIQ::Providers::InfraManager
  require_nested :AuthKeyPair
  require_nested :EmsCluster
  require_nested :EventCatcher
  require_nested :EventParser
  require_nested :Host
  require_nested :HostServiceGroup
  require_nested :MetricsCapture
  require_nested :MetricsCollectorWorker
  require_nested :OrchestrationStack
  require_nested :Refresher
  require_nested :RefreshParser
  require_nested :RefreshWorker
  require_nested :Template

  include ManageIQ::Providers::Openstack::ManagerMixin
  include HasManyOrchestrationStackMixin
  include HasNetworkManagerMixin

  before_save :ensure_parent_provider
  before_destroy :destroy_parent_provider
  before_create :ensure_managers
  before_update :ensure_managers_zone_and_provider_region

  def ensure_network_manager
    build_network_manager(:type => 'ManageIQ::Providers::Openstack::NetworkManager') unless network_manager
  end

  # A placeholder relation for NetworkTopology to work
  def availability_zones
  end

  def cloud_tenants
    self.class.none
  end

  def host_aggregates
    HostAggregate.where(:ems_id => provider.try(:cloud_ems).try(:collect, &:id).try(:uniq))
  end

  def ensure_parent_provider
    # TODO(lsmola) this might move to a general management of Providers, but for now, we will ensure, every
    # EmsOpenstackInfra has associated a Provider. This relation will serve for relating EmsOpenstackInfra
    # to possible many EmsOpenstacks deployed through EmsOpenstackInfra

    # Name of the provider needs to be unique, get provider if there is one like that
    self.provider = ManageIQ::Providers::Openstack::Provider.find_by(:name => name) unless provider

    attributes = {:name => name, :zone => zone}
    if provider
      provider.update_attributes!(attributes)
    else
      self.provider = ManageIQ::Providers::Openstack::Provider.create!(attributes)
    end
  end

  def destroy_parent_provider
    provider.try(:destroy)
  end

  def self.ems_type
    @ems_type ||= "openstack_infra".freeze
  end

  def self.description
    @description ||= "OpenStack Platform Director".freeze
  end

  def self.default_blacklisted_event_names
    %w(
      identity.authenticate
    )
  end

  def supports_port?
    true
  end

  def supports_api_version?
    true
  end

  def supports_security_protocol?
    true
  end

  def supported_auth_types
    %w(default amqp ssh_keypair)
  end

  def supported_auth_attributes
    %w(userid password auth_key)
  end

  def supports_authentication?(authtype)
    supported_auth_types.include?(authtype.to_s)
  end

  def supported_catalog_types
    %w(openstack)
  end

  def self.event_monitor_class
    ManageIQ::Providers::Openstack::InfraManager::EventCatcher
  end

  def verify_credentials(auth_type = nil, options = {})
    auth_type ||= 'default'

    raise MiqException::MiqHostError, "No credentials defined" if missing_credentials?(auth_type)

    options[:auth_type] = auth_type
    case auth_type.to_s
    when 'default'     then verify_api_credentials(options)
    when 'amqp'        then verify_amqp_credentials(options)
    when 'ssh_keypair' then verify_ssh_keypair_credentials(options)
    else               raise "Invalid OpenStack Authentication Type: #{auth_type.inspect}"
    end
  end

  def required_credential_fields(type)
    case type.to_s
    when 'ssh_keypair' then [:userid, :auth_key]
    else                    [:userid, :password]
    end
  end

  def verify_ssh_keypair_credentials(_options)
    # Select one powered-on host in each cluster to verify
    # ssh credentials against
    hosts.select(&:ems_cluster_id)
         .sort_by(&:ems_cluster_id)
         .slice_when { |i, j| i.ems_cluster_id != j.ems_cluster_id }
         .map { |c| c.find { |h| h.power_state == 'on' } }.compact
         .all? { |h| h.verify_credentials('ssh_keypair') }
  end
  private :verify_ssh_keypair_credentials

  def workflow_service
    openstack_handle.detect_workflow_service
  end

  def register_and_configure_nodes(nodes_json)
    connection = openstack_handle.detect_workflow_service
    workflow = "tripleo.baremetal.v1.register_or_update"
    input = { :nodes_json => nodes_json }
    response = connection.create_execution(workflow, input)
    state = response.body["state"]
    workflow_execution_id = response.body["id"]

    while state == "RUNNING"
      sleep 5
      response = connection.get_execution(workflow_execution_id)
      state = response.body["state"]
    end

    EmsRefresh.queue_refresh(@infra) if state == "SUCCESS"

    # Configures boot image for all manageable nodes.
    # It would be preferred to only configure the nodes that were just added, but
    # we don't know the uuids from the response. The uuids are available in Zaqar.
    # Once we add support for reading Zaqar, we can change this to be more
    # selective.
    connection.create_execution("tripleo.baremetal.v1.configure_manageable_nodes")

    [state, response.body.to_s]
  end

  # unsupported Host operations, validate is called in hosts_center view
  def validate_shutdown
    {:available => false,   :message => nil}
  end

  def self.display_name(number = 1)
    n_('Infrastructure Provider (OpenStack)', 'Infrastructure Providers (OpenStack)', number)
  end

  # For infra, validate primary endpoint *and* verify presence of ironic
  def self.validate_credentials_task(args, user_id, zone)
    task_opts = {
      :action => "Validate EMS Provider Credentials",
      :userid => user_id
    }

    queue_opts = {
      :args        => [*args],
      :class_name  => self,
      :method_name => "validate_credentials_undercloud",
      :queue_name  => "generic",
      :role        => "ems_operations",
      :zone        => zone
    }

    task_id = MiqTask.generic_action_with_callback(task_opts, queue_opts)
    task = MiqTask.wait_for_taskid(task_id, :timeout => 30)

    if task.nil?
      error_message = "Task Error"
    elsif MiqTask.status_error?(task.status) || MiqTask.status_timeout?(task.status)
      error_message = task.message
    end

    # Don't fail if ironic isn't found, but provide warning message for user.
    [(error_message.blank? || error_message[0, 9] == "Baremetal"), error_message]
  end

  # For infra, validate primary endpoint *and* verify presence of ironic
  def self.validate_credentials_undercloud(*params)
    if raw_connect(*params)
      begin
        !!raw_connect(*params, "Baremetal")
      rescue MiqException::ServiceNotAvailable
        raise MiqException::ServiceNotAvailable, "Baremetal(Ironic) service not found. Some infrastructure features may be disabled."
      end
    end
  end
end
