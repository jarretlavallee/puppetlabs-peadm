# This profile is not intended to be continously enforced on PE masters.
# Rather, it describes state to enforce as a boostrap action, preparing the
# Puppet Enterprise console with a sane default environment configuration.
#
# This class will be applied during master bootstrap using e.g.
#
#     puppet apply \
#       --exec 'class { "peadm::setup::node_manager":
#                 environments => ["production", "staging", "development"],
#               }'
#
# @param compiler_pool_address 
#   The service address used by agents to connect to compilers, or the Puppet
#   service. Typically this is a load balancer.
# @param internal_compiler_a_pool_address
#   A load balancer address directing traffic to any of the "A" pool
#   compilers. This is used for DR/HA configuration in large and extra large
#   architectures.
# @param internal_compiler_b_pool_address
#   A load balancer address directing traffic to any of the "B" pool
#   compilers. This is used for DR/HA configuration in large and extra large
#   architectures.
#
class peadm::setup::node_manager (
  # Standard
  String[1] $master_host,

  # High Availability
  Optional[String[1]] $master_replica_host            = undef,

  # Common
  Optional[String[1]] $compiler_pool_address            = undef,
  Optional[String[1]] $internal_compiler_a_pool_address = $master_host,
  Optional[String[1]] $internal_compiler_b_pool_address = $master_replica_host,

  # For the next two parameters, the default values are appropriate when
  # deploying Standard or Large architectures. These values only need to be
  # specified differently when deploying an Extra Large architecture.

  # Specify when using Extra Large
  String[1]           $puppetdb_database_host         = $master_host,

  # Specify when using Extra Large AND High Availability
  Optional[String[1]] $puppetdb_database_replica_host = $master_replica_host,
) {

  # Preserve existing user data and classes values. We only need to make sure
  # the values we care about are present; we don't need to remove anything
  # else.
  Node_group {
    purge_behavior => none,
  }

  ##################################################
  # PE INFRASTRUCTURE GROUPS
  ##################################################

  # We modify this group's rule such that all PE infrastructure nodes will be
  # members.
  node_group { 'PE Infrastructure Agent':
    rule => ['or',
      ['~', ['trusted', 'extensions', peadm::oid('peadm_role')], '^puppet/'],
      ['~', ['fact', 'pe_server_version'], '.+']
    ],
  }

  # We modify PE Master to add, as data, the compiler_pool_address only.
  # Because the group does not have any data by default this does not impact
  # out-of-box configuration of the group.
  $compiler_pool_address_data = $compiler_pool_address ? {
    undef   => undef,
    default => { 'pe_repo' => { 'compile_master_pool_address' => $compiler_pool_address } },
  }

  node_group { 'PE Master':
    parent    => 'PE Infrastructure',
    data      => $compiler_pool_address_data,
    variables => { 'pe_master' => true },
    rule      => ['or',
      ['and', ['=', ['trusted', 'extensions', 'pp_auth_role'], 'pe_compiler']],
      ['=', 'name', $master_host],
    ],
  }

  # This group should pin master, puppetdb_database, and puppetdb_database_replica,
  # but only if provided (and not just the default).
  node_group { 'PE Database':
    rule => ['or',
      ['and', ['=', ['trusted', 'extensions', peadm::oid('peadm_role')], 'puppet/puppetdb-database']],
      ['=', 'name', $master_host],
    ]
  }

  # Create data-only groups to store PuppetDB PostgreSQL database configuration
  # information specific to the master and master replica nodes.
  node_group { 'PE Master A':
    ensure => present,
    parent => 'PE Infrastructure',
    rule   => ['and',
      ['=', ['trusted', 'extensions', peadm::oid('peadm_role')], 'puppet/master'],
      ['=', ['trusted', 'extensions', peadm::oid('peadm_availability_group')], 'A'],
    ],
    data   => {
      'puppet_enterprise::profile::primary_master_replica' => {
        'database_host_puppetdb' => $puppetdb_database_host,
      },
      'puppet_enterprise::profile::puppetdb'               => {
        'database_host' => $puppetdb_database_host,
      },
    },
  }

  # Configure the A pool for compilers. There are up to two pools for HA, each
  # having an affinity for one "availability zone" or the other.
  node_group { 'PE Compiler Group A':
    ensure  => 'present',
    parent  => 'PE Compiler',
    rule    => ['and',
      ['=', ['trusted', 'extensions', 'pp_auth_role'], 'pe_compiler'],
      ['=', ['trusted', 'extensions', peadm::oid('peadm_availability_group')], 'A'],
    ],
    classes => {
      'puppet_enterprise::profile::puppetdb' => {
        'database_host' => $puppetdb_database_host,
      },
      'puppet_enterprise::profile::master'   => {
        'puppetdb_host' => ['${trusted[\'certname\']}', $internal_compiler_b_pool_address].filter |$_| { $_ }, # lint:ignore:single_quote_string_with_variables
        'puppetdb_port' => [8081],
      }
    },
    data    => {
      # Workaround for GH-118
      'puppet_enterprise::profile::master::puppetdb' => {
        'ha_enabled_replicas' => [ ],
      },
    },
  }

  # Create the replica and B groups if a replica master and database host are
  # supplied
  if $master_replica_host {
    # We need to pre-create this group so that the master replica can be
    # identified as running PuppetDB, so that Puppet will create a pg_ident
    # authorization rule for it on the PostgreSQL nodes.
    node_group { 'PE HA Replica':
      ensure    => 'present',
      parent    => 'PE Infrastructure',
      rule      => ['or', ['=', 'name', $master_replica_host]],
      classes   => {
        'puppet_enterprise::profile::primary_master_replica' => { }
      },
      variables => { 'peadm_replica' => true },
    }

    node_group { 'PE Master B':
      ensure => present,
      parent => 'PE Infrastructure',
      rule   => ['and',
        ['=', ['trusted', 'extensions', peadm::oid('peadm_role')], 'puppet/master'],
        ['=', ['trusted', 'extensions', peadm::oid('peadm_availability_group')], 'B'],
      ],
      data   => {
        'puppet_enterprise::profile::primary_master_replica' => {
          'database_host_puppetdb' => $puppetdb_database_replica_host,
        },
        'puppet_enterprise::profile::puppetdb'               => {
          'database_host' => $puppetdb_database_replica_host,
        },
      },
    }

    node_group { 'PE Compiler Group B':
      ensure  => 'present',
      parent  => 'PE Compiler',
      rule    => ['and',
        ['=', ['trusted', 'extensions', 'pp_auth_role'], 'pe_compiler'],
        ['=', ['trusted', 'extensions', peadm::oid('peadm_availability_group')], 'B'],
      ],
      classes => {
        'puppet_enterprise::profile::puppetdb' => {
          'database_host' => $puppetdb_database_replica_host,
        },
        'puppet_enterprise::profile::master'   => {
          'puppetdb_host' => ['${trusted[\'certname\']}', $internal_compiler_a_pool_address], # lint:ignore:single_quote_string_with_variables
          'puppetdb_port' => [8081],
        }
      },
      data    => {
        # Workaround for GH-118
        'puppet_enterprise::profile::master::puppetdb' => {
          'ha_enabled_replicas' => [ ],
        },
      },
    }
  }

}
