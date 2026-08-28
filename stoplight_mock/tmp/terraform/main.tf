# Provider configuration
# Pointed at the emulator shim (Docker service name) instead of real Prism Central

provider "nutanix" {
  endpoint     = var.nutanix_endpoint
  port         = var.nutanix_port
  username     = var.nutanix_username
  password     = var.nutanix_password
  insecure     = var.nutanix_insecure
  wait_timeout = 120

  # Suppress "Disabled Providers: foundation, ndb" warnings.
  # These sub-providers require endpoints to enable but are unused in this config.
  foundation_endpoint = var.nutanix_endpoint
  foundation_port     = var.nutanix_port
  ndb_endpoint        = var.nutanix_endpoint
  ndb_username        = var.nutanix_username
  ndb_password        = var.nutanix_password
}

# ── VM resource ──────────────────────────────────────────────────────
# Minimum-configuration VM following the backup provider example pattern.
# Uses hardcoded ext_ids because the emulator's API path format differs
# from the real Nutanix API (provider uses /api/nutanix/... paths).

resource "nutanix_virtual_machine_v2" "example" {
  name                 = var.vm_name
  description          = var.vm_description
  num_cores_per_socket = var.vm_num_cores_per_socket
  num_sockets          = var.vm_num_sockets
  memory_size_bytes    = var.vm_memory_size_bytes
  power_state          = "ON"

  cluster {
    ext_id = var.cluster_ext_id
  }

  nics {
    network_info {
      nic_type = "NORMAL_NIC"
      subnet {
        ext_id = var.subnet_ext_id
      }
      should_allow_unknown_macs = true
    }
  }

  disks {
    disk_address {
      bus_type = "SCSI"
      index    = 0
    }
    backing_info {
      vm_disk {
        disk_size_bytes = var.vm_disk_size_bytes
        storage_container {
          ext_id = var.storage_container_ext_id
        }
      }
    }
  }

  boot_config {
    legacy_boot {
      boot_order = ["CDROM", "DISK", "NETWORK"]
    }
  }

  guest_customization {
    config {
      cloud_init {
        cloud_init_script {
          user_data {
            value = base64encode(<<-EOF
              #cloud-config
              hostname: ${var.vm_name}
              users:
                - name: nutanix
                  sudo: ALL=(ALL) NOPASSWD:ALL
                  ssh_authorized_keys: []
              package_update: true
              package_upgrade: true
            EOF
            )
          }
        }
        datasource_type = "CONFIG_DRIVE_V2"
      }
    }
  }

  lifecycle {
    ignore_changes = [
      guest_customization, cd_roms
    ]
  }
}

# ── Outputs ─────────────────────────────────────────────────────────

output "vm_ext_id" {
  description = "External ID of the provisioned VM"
  value       = resource.nutanix_virtual_machine_v2.example.ext_id
}

output "vm_name" {
  description = "Name of the provisioned VM"
  value       = resource.nutanix_virtual_machine_v2.example.name
}

output "vm_power_state" {
  description = "Power state of the VM after provisioning"
  value       = resource.nutanix_virtual_machine_v2.example.power_state
}
