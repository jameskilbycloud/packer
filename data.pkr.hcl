# =============================================================================
# Content Library ISO lookups
# =============================================================================
# One data source per Ubuntu release, resolving the install ISO to the
# `<library>/<item>/<file>` path that vsphere-iso's `iso_paths` accepts. The
# builder converts that form into the real datastore path itself at CD-ROM
# mount time (driver.FindContentLibraryFileDatastorePath), so nothing here
# needs to know which datastore backs the library.
#
# This replaces the govc + python UUID plumbing that build-templates.yml used
# to run before `packer init` — it listed the library, pulled the library and
# item UUIDs out of `govc library.info -json`, and hand-assembled
# `[datastore] contentlib-{lib-uuid}/{item-uuid}/{file}`. Requires plugin
# 2.3.0+ (data sources landed in #784).
#
# Item vs file name — `govc library.import` names the item after the file's
# basename with the extension stripped, so the item is
# `ubuntu-26.04-live-server-amd64` and the file inside it is
# `ubuntu-26.04-live-server-amd64.iso`. The `name` filter below matches the
# ITEM, hence no `.iso` suffix. scripts/upload-isos.sh relies on the same
# convention (see its "Library item existence check").
#
# The `*` before `-live-server` absorbs point-release drift: 26.04, 26.04.1 and
# 26.04.2 all match, which is what the old resolver's third-tier fallback was
# doing by hand. `latest = true` then picks the most recently modified match
# rather than erroring on ambiguity — so a new point release is picked up as
# soon as upload-isos.yml lands it, with no variable to bump.
#
# Server and desktop builds of a release share one ISO (both sources reference
# the same local.ubuntu entry), so three data sources cover all six builds.
#
# Note: `packer validate` does not evaluate data sources unless given
# -evaluate-datasources, so validate.yml still runs offline against
# placeholder credentials. `packer build` always evaluates them, which means a
# reachable Content Library is now required to build.

data "vsphere-content-library-item" "ubuntu_2204_iso" {
  vcenter_server      = var.vsphere_server
  username            = var.vsphere_user
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection
  datacenter          = var.vsphere_datacenter

  content_library = var.vsphere_iso_content_library
  name            = "ubuntu-22.04*-live-server-amd64"
  type            = "iso"
  latest          = true
}

data "vsphere-content-library-item" "ubuntu_2404_iso" {
  vcenter_server      = var.vsphere_server
  username            = var.vsphere_user
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection
  datacenter          = var.vsphere_datacenter

  content_library = var.vsphere_iso_content_library
  name            = "ubuntu-24.04*-live-server-amd64"
  type            = "iso"
  latest          = true
}

data "vsphere-content-library-item" "ubuntu_2604_iso" {
  vcenter_server      = var.vsphere_server
  username            = var.vsphere_user
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection
  datacenter          = var.vsphere_datacenter

  content_library = var.vsphere_iso_content_library
  name            = "ubuntu-26.04*-live-server-amd64"
  type            = "iso"
  latest          = true
}
