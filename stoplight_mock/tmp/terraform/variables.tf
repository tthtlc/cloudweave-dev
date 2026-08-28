# ── Provider configuration ───────────────────────────────────────────

variable "nutanix_endpoint" {
  description = "Hostname or IP of Prism Central (no scheme — provider adds https:// and port)"
  type        = string
  default     = "emulator"
}

variable "nutanix_port" {
  description = "Prism Central port"
  type        = number
  default     = 9440
}

variable "nutanix_username" {
  description = "Prism Central username"
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "nutanix_password" {
  description = "Prism Central password"
  type        = string
  default     = "Nutanix.123"
  sensitive   = true
}

variable "nutanix_insecure" {
  description = "Skip TLS verification"
  type        = bool
  default     = true
}

# ── VM resource variables ────────────────────────────────────────────

variable "vm_name" {
  description = "Name of the virtual machine"
  type        = string
  default     = "emulator-test-vm"
}

variable "vm_description" {
  description = "Description of the VM"
  type        = string
  default     = "VM provisioned against the Nutanix emulator"
}

variable "vm_num_sockets" {
  description = "Number of vCPU sockets"
  type        = number
  default     = 1
}

variable "vm_num_cores_per_socket" {
  description = "Number of cores per vCPU socket"
  type        = number
  default     = 1
}

variable "vm_memory_size_bytes" {
  description = "Memory size in bytes"
  type        = number
  default     = 4294967296
}

variable "vm_disk_size_bytes" {
  description = "Disk size in bytes"
  type        = number
  default     = 10737418240
}

# ── Reference ext_ids (emulator seed data) ──────────────────────────

variable "cluster_ext_id" {
  description = "Cluster external ID (emulator seed)"
  type        = string
  default     = "00000000-0000-0000-0000-000000000001"
}

variable "subnet_ext_id" {
  description = "Subnet external ID (emulator seed)"
  type        = string
  default     = "00000000-0000-0000-0000-000000000002"
}

variable "image_ext_id" {
  description = "Image external ID (emulator seed)"
  type        = string
  default     = "00000000-0000-0000-0000-000000000003"
}

variable "storage_container_ext_id" {
  description = "Storage container external ID (emulator seed)"
  type        = string
  default     = "00000000-0000-0000-0000-000000000005"
}
