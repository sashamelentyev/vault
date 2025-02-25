scenario "agent" {
  matrix {
    arch            = ["amd64", "arm64"]
    artifact_source = ["local", "crt", "artifactory"]
    distro          = ["ubuntu", "rhel"]
    edition         = ["oss", "ent"]
  }

  terraform_cli = terraform_cli.default
  terraform     = terraform.default
  providers = [
    provider.aws.default,
    provider.enos.ubuntu,
    provider.enos.rhel
  ]

  locals {
    build_tags = {
      "oss" = ["ui"]
      "ent" = ["enterprise", "ent"]
    }
    bundle_path             = matrix.artifact_source != "artifactory" ? abspath(var.vault_bundle_path) : null
    dependencies_to_install = ["jq"]
    enos_provider = {
      rhel   = provider.enos.rhel
      ubuntu = provider.enos.ubuntu
    }
    install_artifactory_artifact = local.bundle_path == null
    tags = merge({
      "Project Name" : var.project_name
      "Project" : "Enos",
      "Environment" : "ci"
    }, var.tags)
    vault_instance_types = {
      amd64 = "t3a.small"
      arm64 = "t4g.small"
    }
    vault_instance_type = coalesce(var.vault_instance_type, local.vault_instance_types[matrix.arch])
    vault_license_path  = abspath(var.vault_license_path != null ? var.vault_license_path : joinpath(path.root, "./support/vault.hclic"))
  }

  step "get_local_metadata" {
    skip_step = matrix.artifact_source != "local"
    module    = module.get_local_metadata
  }

  step "build_vault" {
    module = "build_${matrix.artifact_source}"

    variables {
      build_tags            = try(var.vault_local_build_tags, local.build_tags[matrix.edition])
      bundle_path           = local.bundle_path
      goarch                = matrix.arch
      goos                  = "linux"
      artifactory_host      = matrix.artifact_source == "artifactory" ? var.artifactory_host : null
      artifactory_repo      = matrix.artifact_source == "artifactory" ? var.artifactory_repo : null
      artifactory_username  = matrix.artifact_source == "artifactory" ? var.artifactory_username : null
      artifactory_token     = matrix.artifact_source == "artifactory" ? var.artifactory_token : null
      arch                  = matrix.artifact_source == "artifactory" ? matrix.arch : null
      vault_product_version = var.vault_product_version
      artifact_type         = matrix.artifact_source == "artifactory" ? var.vault_artifact_type : null
      distro                = matrix.artifact_source == "artifactory" ? matrix.distro : null
      edition               = matrix.artifact_source == "artifactory" ? matrix.edition : null
      instance_type         = matrix.artifact_source == "artifactory" ? local.vault_instance_type : null
      revision              = var.vault_revision
    }
  }

  step "find_azs" {
    module = module.az_finder

    variables {
      instance_type = [
        var.backend_instance_type,
        local.vault_instance_type
      ]
    }
  }

  step "create_vpc" {
    module = module.create_vpc

    variables {
      ami_architectures  = [matrix.arch]
      availability_zones = step.find_azs.availability_zones
      common_tags        = local.tags
    }
  }

  step "read_license" {
    skip_step = matrix.edition == "oss"
    module    = module.read_license

    variables {
      file_name = local.vault_license_path
    }
  }

  step "create_backend_cluster" {
    module     = "backend_raft"
    depends_on = [step.create_vpc]

    providers = {
      enos = provider.enos.ubuntu
    }

    variables {
      ami_id        = step.create_vpc.ami_ids["ubuntu"][matrix.arch]
      common_tags   = local.tags
      instance_type = var.backend_instance_type
      kms_key_arn   = step.create_vpc.kms_key_arn
      vpc_id        = step.create_vpc.vpc_id
    }
  }

  step "create_vault_cluster" {
    module = module.vault_cluster
    depends_on = [
      step.create_backend_cluster,
      step.build_vault,
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      ami_id                    = step.create_vpc.ami_ids[matrix.distro][matrix.arch]
      common_tags               = local.tags
      consul_cluster_tag        = step.create_backend_cluster.consul_cluster_tag
      dependencies_to_install   = local.dependencies_to_install
      instance_type             = local.vault_instance_type
      kms_key_arn               = step.create_vpc.kms_key_arn
      storage_backend           = "raft"
      unseal_method             = "shamir"
      vault_local_artifact_path = local.bundle_path
      vault_artifactory_release = local.install_artifactory_artifact ? step.build_vault.vault_artifactory_release : null
      vault_license             = matrix.edition != "oss" ? step.read_license.license : null
      vpc_id                    = step.create_vpc.vpc_id
    }
  }

  step "start_vault_agent" {
    module = "vault_agent"
    depends_on = [
      step.create_backend_cluster,
      step.build_vault,
      step.create_vault_cluster,
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_instances                  = step.create_vault_cluster.vault_instances
      vault_root_token                 = step.create_vault_cluster.vault_root_token
      vault_agent_template_destination = "/tmp/agent_output.txt"
      vault_agent_template_contents    = "{{ with secret \\\"auth/token/lookup-self\\\" }}orphan={{ .Data.orphan }} display_name={{ .Data.display_name }}{{ end }}"
    }
  }

  step "verify_vault_agent_output" {
    module = module.vault_verify_agent_output
    depends_on = [
      step.create_vault_cluster,
      step.start_vault_agent,
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_instances                  = step.create_vault_cluster.vault_instances
      vault_agent_template_destination = "/tmp/agent_output.txt"
      vault_agent_expected_output      = "orphan=true display_name=approle"
    }
  }

  output "vault_cluster_instance_ids" {
    description = "The Vault cluster instance IDs"
    value       = step.create_vault_cluster.instance_ids
  }

  output "vault_cluster_pub_ips" {
    description = "The Vault cluster public IPs"
    value       = step.create_vault_cluster.instance_public_ips
  }

  output "vault_cluster_priv_ips" {
    description = "The Vault cluster private IPs"
    value       = step.create_vault_cluster.instance_private_ips
  }

  output "vault_cluster_key_id" {
    description = "The Vault cluster Key ID"
    value       = step.create_vault_cluster.key_id
  }

  output "vault_cluster_root_token" {
    description = "The Vault cluster root token"
    value       = step.create_vault_cluster.vault_root_token
  }

  output "vault_cluster_unseal_keys_b64" {
    description = "The Vault cluster unseal keys"
    value       = step.create_vault_cluster.vault_unseal_keys_b64
  }

  output "vault_cluster_unseal_keys_hex" {
    description = "The Vault cluster unseal keys hex"
    value       = step.create_vault_cluster.vault_unseal_keys_hex
  }

  output "vault_cluster_tag" {
    description = "The Vault cluster tag"
    value       = step.create_vault_cluster.vault_cluster_tag
  }
}
