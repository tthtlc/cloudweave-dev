terraform {
  required_version = "~> 1.9"

  required_providers {
    nutanix = {
      source  = "nutanix/nutanix"
      version = "= 2.2.1"
    }
  }
}
