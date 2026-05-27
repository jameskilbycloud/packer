# =============================================================================
# Makefile — HashiCorp Packer build targets for Ubuntu vSphere templates
# =============================================================================
#
# PRIMARY WORKFLOW — everything runs in GitHub Actions:
#   make secrets             — push variables.pkrvars.hcl values to GitHub secrets
#                              (one-time setup, then trigger builds from Actions UI)
#   make check-iso-updates   — locally preview upstream Ubuntu ISO drift
#                              (pass APPLY=1 to rewrite filenames across the repo)
#
# LOCAL DEVELOPER TARGETS — require Packer + vSphere access on this machine:
#   make init          — download the vsphere plugin
#   make validate      — syntax-check all build files
#   make fmt           — reformat all .pkr.hcl files
#   make build-all     — build every image (sequential)
#
#   make 2204-server   — build Ubuntu 22.04 Server only
#   make 2204-desktop  — build Ubuntu 22.04 Desktop only
#   make 2404-server   — build Ubuntu 24.04 Server only
#   make 2404-desktop  — build Ubuntu 24.04 Desktop only
#   make 2604-server   — build Ubuntu 26.04 Server only
#   make 2604-desktop  — build Ubuntu 26.04 Desktop only
#
#   make 2204          — build both 22.04 images
#   make 2404          — build both 24.04 images
#   make 2604          — build both 26.04 images
#
# All local build targets require variables.pkrvars.hcl to exist.
# Copy variables.pkrvars.hcl.example and fill in your values first.
# =============================================================================

VARS_FILE   := variables.pkrvars.hcl
PACKER_ARGS := -var-file=$(VARS_FILE) -on-error=cleanup

.PHONY: init validate fmt \
        secrets upload-isos check-iso-updates \
        build-all \
        2204 2204-server 2204-desktop \
        2404 2404-server 2404-desktop \
        2604 2604-server 2604-desktop \
        clean

# ── ISO upload ────────────────────────────────────────────────────────────────
# Requires govc env vars to be set — see scripts/upload-isos.sh for full list.
# Example:
#   export GOVC_URL=https://vcenter.example.com
#   export GOVC_USERNAME=administrator@vsphere.local
#   export GOVC_PASSWORD=secret
#   export GOVC_DATACENTER=Datacenter
#   export LIBRARY_DATASTORE=datastore1
#   make upload-isos
#
# Override which versions to upload:
#   UBUNTU_VERSIONS="2404" make upload-isos

upload-isos:
	bash scripts/upload-isos.sh

# ── ISO update check ──────────────────────────────────────────────────────────
# Detect-only by default; pass APPLY=1 to rewrite filenames across the repo.
#
# Examples:
#   make check-iso-updates
#   APPLY=1 make check-iso-updates

check-iso-updates:
	@if [ "$(APPLY)" = "1" ]; then \
	  bash scripts/check-iso-updates.sh --apply; \
	else \
	  bash scripts/check-iso-updates.sh; \
	fi

# ── GitHub Secrets ────────────────────────────────────────────────────────────
# Reads variables.pkrvars.hcl and pushes all values to GitHub Actions secrets.
# Requires the gh CLI authenticated with: gh auth login
#
# Dry-run (show values without pushing):
#   DRY_RUN=true make secrets
#
# Target a different repo:
#   GH_REPO=owner/repo make secrets

secrets: $(VARS_FILE)
	bash scripts/set-github-secrets.sh

# ── Setup ─────────────────────────────────────────────────────────────────────

init:
	packer init .

validate: $(VARS_FILE)
	packer validate $(PACKER_ARGS) .

fmt:
	packer fmt .

# ── Individual builds ─────────────────────────────────────────────────────────

2204-server: $(VARS_FILE)
	packer build $(PACKER_ARGS) -only='*.vsphere-iso.ubuntu-2204-server' .

2204-desktop: $(VARS_FILE)
	packer build $(PACKER_ARGS) -only='*.vsphere-iso.ubuntu-2204-desktop' .

2404-server: $(VARS_FILE)
	packer build $(PACKER_ARGS) -only='*.vsphere-iso.ubuntu-2404-server' .

2404-desktop: $(VARS_FILE)
	packer build $(PACKER_ARGS) -only='*.vsphere-iso.ubuntu-2404-desktop' .

2604-server: $(VARS_FILE)
	packer build $(PACKER_ARGS) -only='*.vsphere-iso.ubuntu-2604-server' .

2604-desktop: $(VARS_FILE)
	packer build $(PACKER_ARGS) -only='*.vsphere-iso.ubuntu-2604-desktop' .

# ── Version-grouped builds ────────────────────────────────────────────────────

2204: 2204-server 2204-desktop

2404: 2404-server 2404-desktop

2604: 2604-server 2604-desktop

# ── Build all ─────────────────────────────────────────────────────────────────

build-all: 2204 2404 2604

# ── Utilities ─────────────────────────────────────────────────────────────────

clean:
	rm -rf manifests/

# Guard: require vars file before any build target
$(VARS_FILE):
	$(error variables.pkrvars.hcl not found. Copy variables.pkrvars.hcl.example and fill in your values)
