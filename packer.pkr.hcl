packer {
  required_version = ">= 1.10.0, < 2.0.0"

  required_plugins {
    vsphere = {
      version = ">= 1.3.0, < 2.0.0"
      source  = "github.com/hashicorp/vsphere"
    }
  }
}
