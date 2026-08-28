# ── Network-centric Terraform configuration ───────────────────────────
# Provisions VPC, subnets, security policies, and floating IPs — no VMs.
# Schema follows the provider v2.2.1 examples under:
#   terraform-provider-nutanix-2.2.1/examples/{vpc_v2,subnets_v2,
#     network_security_policies_v2,floating_ip_v2}

provider "nutanix" {
  endpoint     = var.nutanix_endpoint
  port         = var.nutanix_port
  username     = var.nutanix_username
  password     = var.nutanix_password
  insecure     = var.nutanix_insecure
  wait_timeout = 120

  # Suppress "Disabled Providers: foundation, ndb" warnings
  foundation_endpoint = var.nutanix_endpoint
  foundation_port     = var.nutanix_port
  ndb_endpoint        = var.nutanix_endpoint
  ndb_username        = var.nutanix_username
  ndb_password        = var.nutanix_password
}

# ── Locals ────────────────────────────────────────────────────────────
# Hardcoded cluster ext_id — the emulator doesn't support the clusters
# API, so we use the seed value directly (same pattern as the VM dir).

locals {
  cluster_ext_id = var.cluster_ext_id
}

# ── External VLAN Subnet (prerequisite for VPC) ───────────────────────

resource "nutanix_subnet_v2" "external" {
  name              = var.external_subnet_name
  cluster_reference = local.cluster_ext_id
  subnet_type       = "VLAN"
  network_id        = var.external_subnet_vlan_id
  is_external       = true

  # description is intentionally absent from config — it is CLI-managed.
  # lifecycle ignore_changes prevents the provider from sending the zero
  # value (empty string) in update requests, which would overwrite the
  # out-of-band value set via REST API.
  lifecycle {
    ignore_changes = [description]
  }

  ip_config {
    ipv4 {
      ip_subnet {
        ip {
          value = var.external_subnet_ip
        }
        prefix_length = var.external_subnet_prefix_length
      }
      default_gateway_ip {
        value = var.external_subnet_gateway
      }
      pool_list {
        start_ip {
          value = var.external_subnet_pool_start
        }
        end_ip {
          value = var.external_subnet_pool_end
        }
      }
    }
  }
}

# ── VPC ────────────────────────────────────────────────────────────────

resource "nutanix_vpc_v2" "main" {
  name        = var.vpc_name
  description = var.vpc_description
  vpc_type    = var.vpc_type

  external_subnets {
    subnet_reference = nutanix_subnet_v2.external.id
  }

  # Externally routable IP prefixes (optional)
  dynamic "externally_routable_prefixes" {
    for_each = var.vpc_externally_routable_prefixes
    content {
      ipv4 {
        ip {
          value         = externally_routable_prefixes.value.ip
          prefix_length = externally_routable_prefixes.value.ip_prefix_length
        }
        prefix_length = externally_routable_prefixes.value.prefix_length
      }
    }
  }

  # Common DHCP options for the VPC (optional)
  dynamic "common_dhcp_options" {
    for_each = var.vpc_dhcp_domain_name_servers != null ? [1] : []
    content {
      dynamic "domain_name_servers" {
        for_each = var.vpc_dhcp_domain_name_servers
        content {
          ipv4 {
            value         = domain_name_servers.value.ip
            prefix_length = domain_name_servers.value.prefix_length
          }
        }
      }
    }
  }
}

# ── Overlay Subnet (inside the VPC) ────────────────────────────────────

resource "nutanix_subnet_v2" "overlay" {
  name         = var.overlay_subnet_name
  description  = var.overlay_subnet_description
  subnet_type  = "OVERLAY"
  vpc_reference = nutanix_vpc_v2.main.id

  ip_config {
    ipv4 {
      ip_subnet {
        ip {
          value = var.overlay_subnet_ip
        }
        prefix_length = var.overlay_subnet_prefix_length
      }
      default_gateway_ip {
        value = var.overlay_subnet_gateway
      }
      pool_list {
        start_ip {
          value = var.overlay_subnet_pool_start
        }
        end_ip {
          value = var.overlay_subnet_pool_end
        }
      }
    }
  }

  # Optional DHCP options for the overlay subnet
  dynamic "dhcp_options" {
    for_each = var.overlay_subnet_domain_name_servers != null ? [1] : []
    content {
      dynamic "domain_name_servers" {
        for_each = var.overlay_subnet_domain_name_servers
        content {
          ipv4 {
            value = domain_name_servers.value
          }
        }
      }
      search_domains   = var.overlay_subnet_search_domains
      domain_name      = var.overlay_subnet_domain_name
      tftp_server_name = var.overlay_subnet_tftp_server_name
      boot_file_name   = var.overlay_subnet_boot_file_name
    }
  }
}

# ── Network Security Policy (optional) ─────────────────────────────────

resource "nutanix_network_security_policy_v2" "example" {
  count       = var.create_security_policy ? 1 : 0
  name        = var.security_policy_name
  description = var.security_policy_description
  type        = "APPLICATION"
  state       = "SAVE"

  rules {
    description = "Allow all within secured group"
    type        = "APPLICATION"
    spec {
      application_rule_spec {
        secured_group_category_references = []
        is_all_protocol_allowed           = true
      }
    }
  }

  vpc_reference = [
    nutanix_vpc_v2.main.id,
  ]

  is_hitlog_enabled = false
}

# ── Floating IP (optional) ────────────────────────────────────────────

resource "nutanix_floating_ip_v2" "example" {
  count                     = var.create_floating_ip ? 1 : 0
  name                      = var.floating_ip_name
  description               = var.floating_ip_description
  external_subnet_reference = nutanix_subnet_v2.external.id
}

# ── Outputs ────────────────────────────────────────────────────────────

output "external_subnet_ext_id" {
  description = "External ID of the external VLAN subnet"
  value       = nutanix_subnet_v2.external.ext_id
}

output "external_subnet_name" {
  description = "Name of the external VLAN subnet"
  value       = nutanix_subnet_v2.external.name
}

output "vpc_ext_id" {
  description = "External ID of the VPC"
  value       = nutanix_vpc_v2.main.ext_id
}

output "vpc_name" {
  description = "Name of the VPC"
  value       = nutanix_vpc_v2.main.name
}

output "overlay_subnet_ext_id" {
  description = "External ID of the overlay subnet"
  value       = nutanix_subnet_v2.overlay.ext_id
}

output "overlay_subnet_name" {
  description = "Name of the overlay subnet"
  value       = nutanix_subnet_v2.overlay.name
}

output "overlay_subnet_cidr" {
  description = "CIDR block of the overlay subnet"
  value = format(
    "%s/%d",
    var.overlay_subnet_ip,
    var.overlay_subnet_prefix_length,
  )
}

output "floating_ip_ext_id" {
  description = "External ID of the floating IP (empty if not created)"
  value       = var.create_floating_ip ? nutanix_floating_ip_v2.example[0].ext_id : null
}

output "floating_ip_name" {
  description = "Name of the floating IP (empty if not created)"
  value       = var.create_floating_ip ? nutanix_floating_ip_v2.example[0].name : null
}
