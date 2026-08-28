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

# ── Cluster reference ─────────────────────────────────────────────────

variable "cluster_ext_id" {
  description = "Cluster external ID (emulator seed or discovered from data source)"
  type        = string
  default     = "00000000-0000-0000-0000-000000000001"
}

# ── External VLAN Subnet (prerequisite for VPC) ──────────────────────

variable "external_subnet_name" {
  description = "Name of the external VLAN subnet"
  type        = string
  default     = "emulator-ext-subnet"
}

variable "external_subnet_vlan_id" {
  description = "VLAN ID for the external subnet"
  type        = number
  default     = 112
}

variable "external_subnet_ip" {
  description = "Subnet IP for the external VLAN subnet"
  type        = string
  default     = "192.168.0.0"
}

variable "external_subnet_prefix_length" {
  description = "Prefix length for the external VLAN subnet"
  type        = number
  default     = 24
}

variable "external_subnet_gateway" {
  description = "Default gateway for the external VLAN subnet"
  type        = string
  default     = "192.168.0.1"
}

variable "external_subnet_pool_start" {
  description = "Start of the IP pool for the external VLAN subnet"
  type        = string
  default     = "192.168.0.20"
}

variable "external_subnet_pool_end" {
  description = "End of the IP pool for the external VLAN subnet"
  type        = string
  default     = "192.168.0.30"
}

# ── VPC variables ─────────────────────────────────────────────────────

variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
  default     = "emulator-vpc"
}

variable "vpc_description" {
  description = "Description of the VPC"
  type        = string
  default     = "VPC provisioned against the Nutanix emulator"
}

variable "vpc_type" {
  description = "Type of VPC (REGULAR or TRANSIT)"
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["REGULAR", "TRANSIT"], var.vpc_type)
    error_message = "vpc_type must be REGULAR or TRANSIT"
  }
}

variable "vpc_externally_routable_prefixes" {
  description = "Externally routable IP prefixes for the VPC"
  type = list(object({
    ip               = string
    ip_prefix_length = number
    prefix_length    = number
  }))
  default = []
}

variable "vpc_dhcp_domain_name_servers" {
  description = "Domain name servers for the VPC DHCP options. Set to null to omit."
  type = list(object({
    ip            = string
    prefix_length = number
  }))
  default = null
}

# ── Overlay subnet variables ──────────────────────────────────────────

variable "overlay_subnet_name" {
  description = "Name of the overlay subnet"
  type        = string
  default     = "emulator-overlay-subnet"
}

variable "overlay_subnet_description" {
  description = "Description of the overlay subnet"
  type        = string
  default     = "Overlay subnet inside the VPC"
}

variable "overlay_subnet_ip" {
  description = "Subnet IP for the overlay subnet"
  type        = string
  default     = "10.0.0.0"
}

variable "overlay_subnet_prefix_length" {
  description = "Prefix length for the overlay subnet"
  type        = number
  default     = 24
}

variable "overlay_subnet_gateway" {
  description = "Default gateway for the overlay subnet"
  type        = string
  default     = "10.0.0.1"
}

variable "overlay_subnet_pool_start" {
  description = "Start of the IP pool for the overlay subnet"
  type        = string
  default     = "10.0.0.10"
}

variable "overlay_subnet_pool_end" {
  description = "End of the IP pool for the overlay subnet"
  type        = string
  default     = "10.0.0.250"
}

variable "overlay_subnet_domain_name_servers" {
  description = "Domain name servers for the overlay subnet DHCP options. Set to null to omit."
  type        = list(string)
  default     = null
}

variable "overlay_subnet_search_domains" {
  description = "DNS search domains for the overlay subnet"
  type        = list(string)
  default     = []
}

variable "overlay_subnet_domain_name" {
  description = "DNS domain name for the overlay subnet"
  type        = string
  default     = ""
}

variable "overlay_subnet_tftp_server_name" {
  description = "TFTP server name for the overlay subnet DHCP options"
  type        = string
  default     = ""
}

variable "overlay_subnet_boot_file_name" {
  description = "Boot file name for the overlay subnet DHCP options"
  type        = string
  default     = ""
}

# ── Network Security Policy variables ─────────────────────────────────

variable "create_security_policy" {
  description = "Whether to create an example network security policy"
  type        = bool
  default     = false
}

variable "security_policy_name" {
  description = "Name of the network security policy"
  type        = string
  default     = "emulator-security-policy"
}

variable "security_policy_description" {
  description = "Description of the network security policy"
  type        = string
  default     = "Example APPLICATION security policy"
}

# ── Floating IP variables ─────────────────────────────────────────────

variable "create_floating_ip" {
  description = "Whether to create an example floating IP"
  type        = bool
  default     = false
}

variable "floating_ip_name" {
  description = "Name of the floating IP"
  type        = string
  default     = "emulator-floating-ip"
}

variable "floating_ip_description" {
  description = "Description of the floating IP"
  type        = string
  default     = "Example floating IP on the external subnet"
}
