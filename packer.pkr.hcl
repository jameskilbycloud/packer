packer {
  required_version = ">= 1.14.0"

  required_plugins {
    vsphere = {
      version = ">= 2.1.2"
      source  = "github.com/vmware/vsphere"
    }
  }
}
