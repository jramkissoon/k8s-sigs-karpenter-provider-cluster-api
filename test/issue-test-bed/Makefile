#  Copyright 2026 Julian Ramkissoon
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

# Issue test bed: Karpenter on a CAPD workload cluster built from a
# ClusterClass, deployed from this branch. Run make from this directory.
# Help format: https://suva.sh/posts/well-documented-makefiles
#
#   make clusters               kind cluster -> overlays/dev at its revision -> workload add-ons
#   make deploy REVISION=<NN-…>  set overlays/dev to one revision (yq) and apply it
#   make upgrade TO=<NN-…>       the same, only for the next step, waiting it out
#   make workloads              the test apps overlay, on the workload cluster
#   make down                  tear it all back down

# Strict Bash flags live in SHELL because GNU Make 3.81 (macOS) lacks .ONESHELL.
SHELL := /bin/bash -euo pipefail
.SHELLFLAGS := -c

MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules

.EXPORT_ALL_VARIABLES:

##@ General

.DEFAULT_GOAL := help

.PHONY: help
help:  ## Display this help menu
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	     /^[a-zA-Z_0-9%-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } \
	     /^define [a-zA-Z_-]+ *##/ { split($$0, d, "##"); split(d[1], n, " "); printf "  \033[36m%-22s\033[0m %s\n", n[2], d[2] } \
	     /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: env
env:  ## Print dev environment exports; use: eval "$(make env)"
	@echo "export PATH=$(TOOLS_BIN_DIR):\$$PATH"
	@echo "export KUBECONFIG=$(abspath $(CLUSTER_KUBECONFIG))"


# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

ROOT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
BIN_DIR := bin
HACK_DIR := hack
# The layout (see README.md). Every Kubernetes manifest is under kubernetes/;
# what gets deployed is kubernetes/overlays/dev:
#   clusters/management/        to the MANAGEMENT cluster: the base plus ONE
#                               revision component, rewritten by `make deploy`
#   clusters/karpenter-docker/  INSIDE the workload cluster: its add-ons
#   workloads/                  INSIDE the workload cluster: the test apps
# kubernetes/components/revisions/NN-<k8s>-<class>/ are the revisions, one per
# node upgrade step, numbered in order; kubernetes/base/ is what all of it is
# built from.
MANIFESTS_DIR       := kubernetes
CLUSTERS_DIR        := $(MANIFESTS_DIR)/base/clusters
INFRASTRUCTURE_REVISIONS_DIR := $(MANIFESTS_DIR)/components/revisions
MANAGEMENT_OVERLAY  := $(MANIFESTS_DIR)/overlays/dev/clusters/management
ADDONS_OVERLAY      := $(MANIFESTS_DIR)/overlays/dev/clusters/karpenter-docker
WORKLOADS_OVERLAY   := $(MANIFESTS_DIR)/overlays/dev/workloads
# How the management overlay names a revision component, relative to itself.
REVISION_COMPONENT  := ../../../../components/revisions
# The revisions in upgrade order: the folder names under
# INFRASTRUCTURE_REVISIONS_DIR, which their NN- prefixes sort.
REVISIONS           := $(sort $(notdir $(patsubst %/,%,$(wildcard $(INFRASTRUCTURE_REVISIONS_DIR)/*/))))
KUBECONFIG_DIR := kubeconfig
TOOLS_DIR := $(HACK_DIR)/tools
TOOLS_BIN_DIR := $(abspath $(ROOT_DIR)/$(TOOLS_DIR)/$(BIN_DIR))

export PATH := $(abspath $(TOOLS_BIN_DIR)):$(PATH)

OS ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')
OS_TITLE ?= $(shell uname -s | sed -e 's/darwin/Darwin/' -e 's/linux/Linux/')
ARCH ?= $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

# --- Kubernetes version ------------------------------------------------------

# The management cluster's Kubernetes version (and kubectl's); use a patch the
# pinned kind release ships. The workload cluster's versions belong to the
# revisions.
K8S_VERSION ?= v1.34.11
K8S_MINOR   := $(shell echo $(K8S_VERSION) | sed -E 's/^v?([0-9]+\.[0-9]+).*/\1/')

# --- Cluster ------------------------------------------------------------------

CLUSTER_NAME ?= capi-karpenter-test
CLUSTER_KIND_CONFIG ?= kind-config.yaml
CLUSTER_KUBECONFIG  ?= $(KUBECONFIG_DIR)/$(CLUSTER_NAME).kubeconfig
CLUSTER_KIND_IMAGE  ?= kindest/node:$(K8S_VERSION)

# --- Baseline deployments ----------------------------------------------------

DEPLOY_WAIT_TIMEOUT   ?= 240s
# Server-side apply: the CRDs are too large for client-side apply's annotation.
# --force-conflicts because Cluster API strips managedFields from its objects,
# after which every re-apply is a "conflict" with the previous value. The
# manifests are the source of truth here; the one field a controller owns
# that they must not declare is MachineDeployment replicas, which Karpenter
# scales (the Cluster's topology leaves them unset).
KUBECTL_FIELD_MANAGER ?= test-bed
KUBECTL_APPLY         := apply --server-side --force-conflicts --field-manager=$(KUBECTL_FIELD_MANAGER)
# A composite is re-applied until every object is accepted: CRDs, webhooks
# and operator-installed providers come up between passes.
APPLY_RETRIES     ?= 30
APPLY_RETRY_DELAY ?= 10

CLUSTER_KUBECTL := kubectl --kubeconfig $(CLUSTER_KUBECONFIG)

# --- Workload cluster ---------------------------------------------------------

# The workload cluster, kubernetes/base/clusters/karpenter-docker, built from a
# ClusterClass in a namespace of its own name. The kubeconfig is the Secret Cluster API
# writes for the cluster.
WL_CLUSTER_NAME  ?= karpenter-docker
WL_NAMESPACE     ?= $(WL_CLUSTER_NAME)
# Seconds the topology controller is given to pick up a new class or version
# before `make upgrade` checks whether the control plane has converged.
TOPOLOGY_SETTLE  ?= 10
WL_KUBECONFIG    ?= $(KUBECONFIG_DIR)/$(WL_CLUSTER_NAME).kubeconfig
WL_READY_TIMEOUT ?= 10m
WL_KUBECTL       := kubectl --kubeconfig $(WL_KUBECONFIG)

# --- Upgrade path ---------------------------------------------------------------

# REVISION is the revision `make clusters` / `make management` / `make deploy`
# apply: the one the cluster is already at (its test-bed/revision label), so
# re-running them never moves an existing cluster; with no cluster yet, the one
# the management overlay names; failing that, the first.
# $(shell) runs with make's own environment, not the exported PATH above
# (GNU Make 3.81 on macOS), so it is handed the pinned tools explicitly.
REVISION      ?= $(or $(shell PATH="$(TOOLS_BIN_DIR):$$PATH"; $(CURRENT_REVISION_CMD) 2>/dev/null),$(notdir $(shell PATH="$(TOOLS_BIN_DIR):$$PATH"; yq '.components[0] // ""' $(MANAGEMENT_OVERLAY)/kustomization.yaml 2>/dev/null)),$(firstword $(REVISIONS)))
TO            ?=

# --- Karpenter ----------------------------------------------------------------

# Karpenter runs IN the workload cluster, from the provider repo's own Helm
# chart. Neither the chart nor an image is published, so both come from the
# checkout this test bed sits in: the chart is copied into the kustomization,
# and `make karpenter-release` builds the image, imports it into the workload
# control plane node and points components/karpenter-image at it. The builder
# override is needed because the Dockerfile defaults to a Go older than go.mod
# requires.
KARPENTER_REPO           ?= $(abspath $(ROOT_DIR)/../..)
KARPENTER_CHART          := $(KARPENTER_REPO)/charts/karpenter
KARPENTER_CHART_CACHE    := $(CLUSTERS_DIR)/karpenter-docker/addons/karpenter/charts
KARPENTER_IMAGE_COMPONENT := $(MANIFESTS_DIR)/components/karpenter-image
KARPENTER_IMAGE_NAME     ?= karpenter-clusterapi-controller
# The build's tag: the provider commit, plus a hash of the uncommitted changes
# when there are any, so every different build gets a different tag. The test
# bed's own files (this folder, wherever it sits in the repo) are not in the
# image and do not count, or the component file a release rewrites would make
# the next tag differ. Set KARPENTER_TAG to name a build yourself.
TESTBED_PATH             := $(shell git -C "$(ROOT_DIR)" rev-parse --show-prefix 2>/dev/null)
# shasum's output for no input: no uncommitted changes.
EMPTY_SHA1_PREFIX        := da39a3ee
KARPENTER_SHA            := $(shell git -C "$(KARPENTER_REPO)" rev-parse --short=12 HEAD 2>/dev/null)
KARPENTER_DIRTY          := $(shell cd "$(KARPENTER_REPO)" 2>/dev/null && { git diff HEAD -- . ':!$(TESTBED_PATH)'; git ls-files -o --exclude-standard -- . ':!$(TESTBED_PATH)' | git hash-object --stdin-paths; } 2>/dev/null | shasum | cut -c1-8)
KARPENTER_TAG            ?= $(KARPENTER_SHA)$(if $(filter-out $(EMPTY_SHA1_PREFIX),$(KARPENTER_DIRTY)),-dirty-$(KARPENTER_DIRTY))
KARPENTER_IMAGE          := $(KARPENTER_IMAGE_NAME):$(KARPENTER_TAG)
# The image the test bed deploys: what components/karpenter-image names.
KARPENTER_DEPLOYED_IMAGE_CMD := yq '.images[0].newName + ":" + .images[0].newTag' "$(KARPENTER_IMAGE_COMPONENT)/kustomization.yaml"
KARPENTER_BUILDER_IMAGE  ?= docker.io/library/golang:1.25
KARPENTER_NAMESPACE      ?= karpenter
# How Karpenter reaches the management cluster: a token for the ServiceAccount
# clusters/karpenter-docker creates, wrapped in a kubeconfig and shipped to
# the workload cluster as a Secret. Tokens expire; rerun
# `make wl-mgmt-credentials` past this.
KARPENTER_MGMT_SA        ?= karpenter
KARPENTER_TOKEN_DURATION ?= 168h
WL_MGMT_KUBECONFIG       := $(KUBECONFIG_DIR)/$(WL_CLUSTER_NAME)-mgmt.kubeconfig

# --- Workloads ----------------------------------------------------------------

# The replica count is the overlay's (kubernetes/overlays/dev/workloads/scale-up-test); set
# SCALE_UP_REPLICAS to override it for one `make workloads`.
SCALE_UP_DEPLOYMENT ?= scale-up
SCALE_UP_REPLICAS   ?=
WATCH_INTERVAL      ?= 2


# ------------------------------------------------------------------------------
# Tool Declarations
# ------------------------------------------------------------------------------
# To add a tool: copy a block, set <TOOL>_VER / _BASE_URL (required) and any of
# _ASSET, _CHECKSUM_ASSET, _CHECKSUM_FIELD, _TAR_PATH, _RELEASE_URL,
# _RELEASE_PARSE, then keep its `TOOLS += <name>` line. add-tool derives the rest.

TOOLS     :=
TOOL_DEFS :=

# helm - kustomize shells out to it to inflate the charts under kubernetes/base/clusters.
HELM_VER            := v4.1.4
HELM_BASE_URL       := https://get.helm.sh
HELM_ASSET          := helm-$(HELM_VER)-$(OS)-$(ARCH).tar.gz
HELM_CHECKSUM_ASSET := $(HELM_ASSET).sha256
HELM_TAR_PATH       := $(OS)-$(ARCH)/helm
HELM_RELEASE_URL    := https://api.github.com/repos/helm/helm/releases/latest
TOOLS += helm

# Keep helm's caches under hack/tools, never ~/.helm.
export HELM_CACHE_HOME  := $(abspath $(TOOLS_DIR)/cache/helm)
export HELM_CONFIG_HOME := $(abspath $(TOOLS_DIR)/cache/helm-config)
export HELM_DATA_HOME   := $(abspath $(TOOLS_DIR)/cache/helm-data)

# kubectl - pinned to K8S_VERSION; dl.k8s.io returns bare versions, hence `cat`.
KUBECTL_VER            := $(K8S_VERSION)
KUBECTL_BASE_URL       := https://dl.k8s.io/release/$(KUBECTL_VER)/bin/$(OS)/$(ARCH)
KUBECTL_CHECKSUM_ASSET := kubectl.sha256
KUBECTL_RELEASE_URL    := https://dl.k8s.io/release/stable-$(K8S_MINOR).txt
KUBECTL_RELEASE_PARSE  := cat
TOOLS += kubectl

# kustomize - builds the kustomizations here with --enable-helm. Monorepo tags are prefixed kustomize/.
KUSTOMIZE_VER            := v5.8.1
KUSTOMIZE_BASE_URL       := https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/$(KUSTOMIZE_VER)
KUSTOMIZE_ASSET          := kustomize_$(KUSTOMIZE_VER)_$(OS)_$(ARCH).tar.gz
KUSTOMIZE_CHECKSUM_ASSET := checksums.txt
KUSTOMIZE_RELEASE_URL    := https://api.github.com/repos/kubernetes-sigs/kustomize/releases
KUSTOMIZE_RELEASE_PARSE  := grep '"tag_name":' | grep 'kustomize/v' | sed -n '1p' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/kustomize\///'
TOOLS += kustomize

# kind - runs the cluster; K8S_VERSION must be an image this release ships.
KIND_VER            := v0.33.0
KIND_BASE_URL       := https://github.com/kubernetes-sigs/kind/releases/download/$(KIND_VER)
KIND_ASSET          := kind-$(OS)-$(ARCH)
KIND_CHECKSUM_ASSET := $(KIND_ASSET).sha256sum
KIND_RELEASE_URL    := https://api.github.com/repos/kubernetes-sigs/kind/releases/latest
TOOLS += kind

# k9s - terminal UI. Asset name capitalises the OS, hence $(OS_TITLE).
K9S_VER            := v0.50.16
K9S_BASE_URL       := https://github.com/derailed/k9s/releases/download/$(K9S_VER)
K9S_ASSET          := k9s_$(OS_TITLE)_$(ARCH).tar.gz
K9S_CHECKSUM_ASSET := checksums.sha256
K9S_RELEASE_URL    := https://api.github.com/repos/derailed/k9s/releases/latest
TOOLS += k9s

# yq - YAML processor. Its checksums file is a multi-hash table; SHA-256 is column 19.
YQ_VER            := v4.53.6
YQ_BASE_URL       := https://github.com/mikefarah/yq/releases/download/$(YQ_VER)
YQ_ASSET          := yq_$(OS)_$(ARCH)
YQ_CHECKSUM_ASSET := checksums
YQ_CHECKSUM_FIELD := 19
YQ_RELEASE_URL    := https://api.github.com/repos/mikefarah/yq/releases/latest
TOOLS += yq


# ------------------------------------------------------------------------------
# Tool Registry Internals (nothing here changes when adding a tool)
# ------------------------------------------------------------------------------

# Uppercase variable prefix for a tool name: kubectl -> KUBECTL, my-tool -> MY_TOOL.
tool-var = $(shell echo $(1) | tr 'a-z-' 'A-Z_')

# Default release parse: tag_name from a GitHub releases JSON response.
RELEASE_PARSE_JSON := grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'

# $(call add-tool,NAME) - derive NAME's URL, checksum, install path and latest-version
# command from its <TOOL>_* settings. Locals first: assignments inside one $(eval)
# are not visible to its later lines.
define add-tool
  $(eval _U     := $(call tool-var,$(1)))
  $(eval _ASSET := $(if $(strip $($(_U)_ASSET)),$(strip $($(_U)_ASSET)),$(1)))
  $(eval _BASE  := $(strip $($(_U)_BASE_URL)))
  $(eval _CKSUM := $(strip $($(_U)_CHECKSUM_ASSET)))
  $(eval _CFIELD := $(strip $($(_U)_CHECKSUM_FIELD)))
  $(eval _REL   := $(strip $($(_U)_RELEASE_URL)))
  $(eval _PARSE := $(if $(strip $($(_U)_RELEASE_PARSE)),$($(_U)_RELEASE_PARSE),$(RELEASE_PARSE_JSON)))
  $(_U)_BIN           := $(1)
  $(_U)_ASSET         := $(_ASSET)
  $(_U)_TAR_PATH      := $(if $(strip $($(_U)_TAR_PATH)),$(strip $($(_U)_TAR_PATH)),$(1))
  $(_U)_RELEASE_PARSE := $(_PARSE)
  $(_U)_URL           := $(_BASE)/$(_ASSET)
  $(_U)_CHECKSUM_URL  := $(if $(_CKSUM),$(_BASE)/$(_CKSUM),)
  $(_U)_CHECKSUM_FIELD := $(_CFIELD)
  $(_U)_LATEST_CMD    := $(if $(_REL),curl -fsSL --connect-timeout 10 --max-time 20 $(_REL) | $(_PARSE),)
  $(_U)               := $(abspath $(TOOLS_BIN_DIR)/$(1)-$($(_U)_VER))
  TOOL_DEFS           := $(strip $(TOOL_DEFS) $(_U))
endef

# Must follow the define above; a call to an undefined macro expands to nothing.
TOOLS := $(strip $(TOOLS))
$(foreach t,$(TOOLS),$(eval $(call add-tool,$(t))))


# ------------------------------------------------------------------------------
# Targets
# ------------------------------------------------------------------------------


##@ Kind Cluster

# $(call write-cluster-kubeconfig) - export the kind kubeconfig to kubeconfig/.
define write-cluster-kubeconfig
	@mkdir -p "$(KUBECONFIG_DIR)"
	@kind get kubeconfig --name "$(CLUSTER_NAME)" > "$(CLUSTER_KUBECONFIG)"
	@chmod 600 "$(CLUSTER_KUBECONFIG)"
	@echo "✅ $(CLUSTER_KUBECONFIG)"
endef

# Idempotent: an existing cluster of the same name is reused, not recreated.
.PHONY: cluster-kind
cluster-kind: check-docker install-kind ## Create the kind cluster (with the Docker socket mounted for CAPD)
	@test -f "$(CLUSTER_KIND_CONFIG)" || { echo "Error: no kind config at $(CLUSTER_KIND_CONFIG)."; exit 1; }
	@if kind get clusters 2>/dev/null | grep -qx "$(CLUSTER_NAME)"; then \
		echo "kind cluster '$(CLUSTER_NAME)' already exists; reusing it."; \
	else \
		kind create cluster --name "$(CLUSTER_NAME)" --config "$(CLUSTER_KIND_CONFIG)" \
			$(if $(strip $(CLUSTER_KIND_IMAGE)),--image "$(CLUSTER_KIND_IMAGE)",); \
	fi
	$(call write-cluster-kubeconfig)

.PHONY: cluster-kubeconfig
cluster-kubeconfig: install-kind ## Write the kubeconfig to kubeconfig/
	$(call write-cluster-kubeconfig)

.PHONY: cluster-down
cluster-down: install-kind ## Delete the kind cluster
	kind delete cluster --name "$(CLUSTER_NAME)"
	@rm -f "$(CLUSTER_KUBECONFIG)"
	@echo "✅ Cluster '$(CLUSTER_NAME)' deleted"


##@ Clusters

.PHONY: clusters
clusters: cluster-kind management wl-kubeconfig workload ## Create everything: kind cluster, the first revision (or the current one), the workload add-ons with Karpenter
	@echo "✅ $(WL_CLUSTER_NAME) ready. Next: make workloads"

# $(call apply-converged,LABEL,RENDER,KUBECTL) - run the shell command RENDER
# (a kustomize build, or a revision render) and server-side apply its output
# with KUBECTL, repeating until kubectl accepts every object. Partial applies make progress each pass, so this converges once the
# CRDs, webhooks and providers the later objects depend on are up.
define apply-converged
	@log=$$(mktemp); trap 'rm -f "$$log"' EXIT; echo "Applying $(1)..."; started=$$(date +%s); \
	for attempt in $$(seq 1 $(APPLY_RETRIES)); do \
		t0=$$(date +%s); \
		if $(2) | $(3) $(KUBECTL_APPLY) -f - >"$$log" 2>&1; then \
			printf '✅ %s: %s objects applied in %s pass(es), %ss\n' "$(1)" "$$(grep -c 'serverside-applied' "$$log")" "$$attempt" "$$(( $$(date +%s) - started ))"; exit 0; \
		fi; \
		printf '   pass %s (%ss): %s object(s) not yet accepted; retrying in %ss\n' "$$attempt" "$$(( $$(date +%s) - t0 ))" "$$(grep -vc 'serverside-applied$$\|^Warning' "$$log")" "$(APPLY_RETRY_DELAY)"; \
		grep -v 'serverside-applied$$\|^Warning' "$$log" | sed 's/^/      /' | head -4; \
		sleep $(APPLY_RETRY_DELAY); \
	done; \
	echo "Error: $(1) did not converge after $(APPLY_RETRIES) passes:"; grep -v 'serverside-applied$$' "$$log"; exit 1
endef

.PHONY: management
management: install-kustomize install-helm install-kubectl cluster-check ## Deploy revision REVISION (management components and the workload cluster) and wait for both
	@$(MAKE) --no-print-directory deploy REVISION="$(REVISION)"
	@# By status, not --for=condition: the operator leaves Ready's observedGeneration
	@# behind after a spec change (a feature gate, say), which condition waits refuse.
	@echo "Waiting for Cluster API providers..."
	@for p in capi-system/coreprovider/cluster-api kubeadm-bootstrap-system/bootstrapprovider/kubeadm \
	         kubeadm-control-plane-system/controlplaneprovider/kubeadm docker-infrastructure-system/infrastructureprovider/docker; do \
		$(CLUSTER_KUBECTL) wait -n "$${p%%/*}" "$${p#*/}" --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True --timeout="$(DEPLOY_WAIT_TIMEOUT)"; \
	done
	@echo "Waiting for the $(WL_CLUSTER_NAME) control plane..."
	@$(CLUSTER_KUBECTL) wait -n "$(WL_NAMESPACE)" "cluster/$(WL_CLUSTER_NAME)" \
		--for='jsonpath={.status.initialization.controlPlaneInitialized}=true' --timeout="$(WL_READY_TIMEOUT)"
	@$(MAKE) --no-print-directory wl-karpenter-member
	@echo "✅ Management cluster complete"

# The Secret's server is the CAPD load balancer's Docker-network address. On
# macOS that is unreachable from the host, so the file copy is pointed at the
# port Docker publishes and TLS verification is dropped (no SAN for 127.0.0.1).
# Pods in the kind cluster use the Secret as written.
.PHONY: wl-kubeconfig
wl-kubeconfig: install-kubectl cluster-check ## Write the workload kubeconfig to kubeconfig/ (rewritten for macOS)
	@mkdir -p "$(KUBECONFIG_DIR)"
	@$(CLUSTER_KUBECTL) get secret -n "$(WL_NAMESPACE)" "$(WL_CLUSTER_NAME)-kubeconfig" \
		-o jsonpath='{.data.value}' | base64 -d > "$(WL_KUBECONFIG)"
	@chmod 600 "$(WL_KUBECONFIG)"
	@if [ "$(OS)" = "darwin" ]; then \
		port=$$(docker port "$(WL_CLUSTER_NAME)-lb" 6443/tcp | sed -n '1p' | awk -F: '{print $$NF}'); \
		[ -n "$$port" ] || { echo "Error: could not read the published port of $(WL_CLUSTER_NAME)-lb."; exit 1; }; \
		$(WL_KUBECTL) config set-cluster "$(WL_CLUSTER_NAME)" --server="https://127.0.0.1:$$port" >/dev/null; \
		$(WL_KUBECTL) config unset "clusters.$(WL_CLUSTER_NAME).certificate-authority-data" >/dev/null; \
		$(WL_KUBECTL) config set "clusters.$(WL_CLUSTER_NAME).insecure-skip-tls-verify" true >/dev/null; \
	fi
	@echo "✅ $(WL_KUBECONFIG)"

.PHONY: workload
workload: install-kustomize install-helm install-kubectl wl-check karpenter-chart wl-mgmt-credentials karpenter-image ## Apply the workload add-ons (Calico, Karpenter from its chart, NodeClass, NodePool) and wait
	$(call apply-converged,$(ADDONS_OVERLAY),kustomize build --enable-helm $(ADDONS_OVERLAY),$(WL_KUBECTL))
	@$(WL_KUBECTL) wait node --all --for=condition=Ready --timeout="$(WL_READY_TIMEOUT)"
	@echo "Waiting for Karpenter..."
	@$(WL_KUBECTL) rollout status -n "$(KARPENTER_NAMESPACE)" deployment/karpenter --timeout="$(DEPLOY_WAIT_TIMEOUT)"
	@echo "✅ Workload cluster complete"

# A kubeconfig for the management cluster that only carries the Karpenter
# ServiceAccount's token, delivered to the workload cluster as the Secret the
# chart mounts. The server is the kind node's Docker-network address, which
# the workload cluster's pods can reach; kind's certificate has no SAN for it,
# so verification is skipped, as the provider's own e2e does.
.PHONY: wl-mgmt-credentials
wl-mgmt-credentials: install-kubectl cluster-check wl-check ## Mint a management-cluster token for Karpenter and store it in the workload cluster
	@mkdir -p "$(KUBECONFIG_DIR)"
	@server="https://$$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(CLUSTER_NAME)-control-plane"):6443"; \
	token=$$($(CLUSTER_KUBECTL) create token "$(KARPENTER_MGMT_SA)" -n "$(WL_NAMESPACE)" --duration="$(KARPENTER_TOKEN_DURATION)"); \
	[ -n "$$token" ] || { echo "Error: could not mint a token for $(WL_NAMESPACE)/$(KARPENTER_MGMT_SA); has 'make management' run?"; exit 1; }; \
	umask 077; printf '%s\n' \
		'apiVersion: v1' 'kind: Config' 'current-context: management' \
		'clusters:' '  - name: management' '    cluster:' "      server: $$server" '      insecure-skip-tls-verify: true' \
		'users:' '  - name: karpenter' '    user:' "      token: $$token" \
		'contexts:' '  - name: management' '    context:' '      cluster: management' '      user: karpenter' \
		> "$(WL_MGMT_KUBECONFIG)"
	@$(WL_KUBECTL) create namespace "$(KARPENTER_NAMESPACE)" --dry-run=client -o yaml | $(WL_KUBECTL) $(KUBECTL_APPLY) -f - >/dev/null
	@$(WL_KUBECTL) create secret generic karpenter-mgmt-kubeconfig -n "$(KARPENTER_NAMESPACE)" \
		--from-file=kubeconfig="$(WL_MGMT_KUBECONFIG)" --dry-run=client -o yaml \
		| $(WL_KUBECTL) $(KUBECTL_APPLY) -f - >/dev/null
	@echo "✅ $(KARPENTER_NAMESPACE)/karpenter-mgmt-kubeconfig (token valid $(KARPENTER_TOKEN_DURATION))"

# The provider only scales MachineDeployments carrying the karpenter-member
# label, and a topology cluster cannot declare it: topology metadata is copied
# onto the Machines too, where the provider reads it as an instance-type
# requirement and its create batcher mistakes every Machine for one it already
# claimed. So the label is added to the MachineDeployment alone; the topology
# controller leaves fields it does not own in place.
.PHONY: wl-karpenter-member
wl-karpenter-member: install-kubectl cluster-check
	@selector="cluster.x-k8s.io/cluster-name=$(WL_CLUSTER_NAME)"; \
	until [ -n "$$($(CLUSTER_KUBECTL) get machinedeployments -n "$(WL_NAMESPACE)" -l "$$selector" -o name)" ]; do sleep 2; done; \
	$(CLUSTER_KUBECTL) label machinedeployments -n "$(WL_NAMESPACE)" -l "$$selector" node.cluster.x-k8s.io/karpenter-member= --overwrite >/dev/null
	@echo "✅ $(WL_CLUSTER_NAME) MachineDeployments labelled for Karpenter"

# Through Cluster API, so CAPD removes its containers; deleting the kind
# cluster first would orphan them.
.PHONY: wl-down
wl-down: install-kubectl cluster-check ## Delete the workload cluster through Cluster API
	-$(CLUSTER_KUBECTL) delete -n "$(WL_NAMESPACE)" "cluster/$(WL_CLUSTER_NAME)" --wait --timeout="$(WL_READY_TIMEOUT)"
	-$(CLUSTER_KUBECTL) delete namespace "$(WL_NAMESPACE)" --wait --timeout="$(DEPLOY_WAIT_TIMEOUT)"
	@rm -f "$(WL_KUBECONFIG)" "$(WL_MGMT_KUBECONFIG)"
	@echo "✅ Workload cluster '$(WL_CLUSTER_NAME)' deleted"


##@ Upgrades

# $(call revision-index,NAME) - shell snippet printing NAME's position among the
# revisions, or -1 when there is no such revision.
revision-index = ls -1 "$(INFRASTRUCTURE_REVISIONS_DIR)" | awk -v name="$(1)" '$$0 == name { print NR - 1; found = 1 } END { if (!found) print -1 }'

# $(call revision-description,NAME) - shell snippet printing the description
# revision NAME's Cluster patch carries.
revision-description = yq '.patches[0].patch' "$(INFRASTRUCTURE_REVISIONS_DIR)/$(1)/kustomization.yaml" | yq '.metadata.annotations["test-bed/revision-description"]'

# The Cluster carries the revision it was last deployed from in its
# test-bed/revision label, set by the revision component's patch; that is what the
# upgrade path is checked against.
CURRENT_REVISION_CMD := $(CLUSTER_KUBECTL) get -n "$(WL_NAMESPACE)" "cluster/$(WL_CLUSTER_NAME)" -o jsonpath='{.metadata.labels.test-bed/revision}'

# Points the management overlay at revision REVISION: its components list
# becomes that one revision component. Changes only the file, not a cluster, so
# `git diff` shows which revision is about to be (or was last) deployed.
.PHONY: set-revision
set-revision: install-yq ## Point overlays/dev/clusters/management at REVISION=<NN-…> (file only)
	@test -n "$(REVISION)" && test -f "$(INFRASTRUCTURE_REVISIONS_DIR)/$(REVISION)/kustomization.yaml" || { echo "Error: no revision '$(REVISION)'; choose from: $(REVISIONS)"; exit 1; }
	@c="$(REVISION_COMPONENT)/$(REVISION)" yq -i '.components = [strenv(c)]' "$(MANAGEMENT_OVERLAY)/kustomization.yaml"
	@echo "✅ $(MANAGEMENT_OVERLAY) -> $(REVISION)"

# Applies the management overlay at one revision: one kustomize build,
# server-side applied to the management cluster, repeated until CRDs and
# webhooks accept everything. Any revision, in any order; `make upgrade` is the
# guarded way along the path.
.PHONY: deploy
deploy: install-kustomize install-helm install-kubectl cluster-check set-revision ## Set overlays/dev to REVISION=<NN-…> (default: the current one) and apply it to the management cluster
	$(call apply-converged,$(MANAGEMENT_OVERLAY) at $(REVISION),kustomize build --enable-helm $(MANAGEMENT_OVERLAY),$(CLUSTER_KUBECTL))

# Applies and returns while worker Machines are still rolling, so the
# interaction with Karpenter can be watched (`make watch`). The control plane
# is waited for, importing the Karpenter image into each new control plane
# node as soon as it runs (from the local build, no network). Karpenter still
# waits for the new node to schedule pods and for its pod network (Calico) to
# start, minutes on a single control plane node; it is only restarted if it has
# not come back after that.
.PHONY: upgrade
upgrade: install-kustomize install-kubectl install-yq cluster-check wl-check ## Deploy TO=<NN-…>, the revision after the current one, and wait for the control plane
	@test -n "$(TO)" || { echo "Error: set TO=<revision>; see 'make upgrade-status'."; exit 1; }
	@current=$$($(CURRENT_REVISION_CMD)); \
	from=$$($(call revision-index,$$current)); to=$$($(call revision-index,$(TO))); \
	[ "$$to" -ge 0 ] || { echo "Error: no revision '$(TO)'; choose from: $(REVISIONS)"; exit 1; }; \
	[ "$$to" -eq $$((from + 1)) ] || { echo "Error: the upgrade path does not allow '$${current:-<none>}' -> '$(TO)'; only the next revision may follow."; exit 1; }; \
	echo "Upgrading $(WL_CLUSTER_NAME): $$current -> $(TO)"
	@kcp_machines() { $(CLUSTER_KUBECTL) get machines -n "$(WL_NAMESPACE)" -l cluster.x-k8s.io/control-plane -o name | sort; }; \
	before=$$(kcp_machines); \
	$(MAKE) --no-print-directory deploy REVISION="$(TO)"; \
	echo "Giving the topology controller $(TOPOLOGY_SETTLE)s to act..."; sleep $(TOPOLOGY_SETTLE); \
	echo "Waiting for the control plane to converge..."; \
	kcp="kubeadmcontrolplanes.v1beta1.controlplane.cluster.x-k8s.io/$$($(CLUSTER_KUBECTL) get kubeadmcontrolplanes -n "$(WL_NAMESPACE)" -l cluster.x-k8s.io/cluster-name=$(WL_CLUSTER_NAME) -o jsonpath='{.items[0].metadata.name}')"; \
	import_new() { $(MAKE) -s --no-print-directory karpenter-import 2>/dev/null | grep '✅' || true; }; \
	until [ "$$($(CLUSTER_KUBECTL) get -n "$(WL_NAMESPACE)" "$$kcp" -o jsonpath='{.metadata.generation}={.status.observedGeneration} {.spec.replicas}={.status.replicas}={.status.updatedReplicas}={.status.readyReplicas} {.spec.version}={.status.version}' 2>/dev/null \
		| awk '{ split($$1,g,"="); split($$2,r,"="); split($$3,v,"="); print (g[1]==g[2] && r[1]==r[2] && r[2]==r[3] && r[3]==r[4] && v[1]==v[2]) }')" = 1 ]; do import_new; sleep 5; done; \
	replicas=$$($(CLUSTER_KUBECTL) get -n "$(WL_NAMESPACE)" "$$kcp" -o jsonpath='{.spec.replicas}'); \
	until [ "$$(kcp_machines | wc -l | tr -d ' ')" = "$$replicas" ]; do import_new; sleep 5; done; \
	if [ "$$(kcp_machines)" != "$$before" ]; then \
		echo "Control plane replaced; checking Karpenter followed it."; \
		$(MAKE) --no-print-directory wl-kubeconfig karpenter-import; \
		$(WL_KUBECTL) rollout status -n "$(KARPENTER_NAMESPACE)" deployment/karpenter --timeout=600s \
			|| $(MAKE) --no-print-directory karpenter-restart; \
	fi
	@echo "✅ $(WL_CLUSTER_NAME) at $(TO). Worker rollouts may still be in progress: make watch"

# Cluster API's own "rollout restart" (what `clusterctl alpha rollout restart`
# does): every worker Machine is replaced through a new MachineSet, the control
# plane is not touched. Set through v1beta2: v1beta1 drops the field.
.PHONY: rollout-restart
rollout-restart: install-kubectl cluster-check ## Roll every worker Machine through a new MachineSet (control plane untouched)
	@md=$$($(CLUSTER_KUBECTL) get machinedeployments -n "$(WL_NAMESPACE)" -l cluster.x-k8s.io/cluster-name=$(WL_CLUSTER_NAME) -o jsonpath='{.items[0].metadata.name}'); \
	$(CLUSTER_KUBECTL) patch machinedeployments.v1beta2.cluster.x-k8s.io -n "$(WL_NAMESPACE)" "$$md" --type merge \
		-p "{\"spec\":{\"rollout\":{\"after\":\"$$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}}" >/dev/null; \
	echo "✅ $$md rolling every worker (rollout.after set to now)"

.PHONY: list-revisions
list-revisions: ## List the available revisions (the folder names under INFRASTRUCTURE_REVISIONS_DIR), in upgrade order
	@printf '%s\n' $(REVISIONS)

.PHONY: upgrade-status
upgrade-status: install-kubectl install-yq cluster-check ## List the revisions in order, the current one and what TO may be next
	@current=$$($(CURRENT_REVISION_CMD) 2>/dev/null || true); \
	for name in $(REVISIONS); do \
		marker="  "; [ "$$name" = "$$current" ] && marker="=>"; \
		printf '%s %-20s %s\n' "$$marker" "$$name" "$$($(call revision-description,$$name))"; \
	done; \
	next=$$(ls -1 "$(INFRASTRUCTURE_REVISIONS_DIR)" | sed -n "$$(( $$($(call revision-index,$$current)) + 2 ))p"); \
	echo; echo "current: $${current:-<none>}   next: $${next:-<end of the path>}"

# One row per Machine, joined across both clusters: the management side says
# which MachineSet (rollout), infra and bootstrap template made it and whether
# Karpenter claimed it; the workload side says whether its Node is Ready and
# which NodeClaim owns it. Labels come from the revision and template versions.
OVERVIEW_TAB := {"\t"}
OVERVIEW_NL  := {"\n"}

.PHONY: overview
overview: install-kubectl cluster-check ## Table of the workload cluster: revision, then one row per Machine with its templates, Node and NodeClaim
	@echo "$(WL_CLUSTER_NAME) @ $$($(CURRENT_REVISION_CMD) 2>/dev/null || true): $$($(CLUSTER_KUBECTL) get -n "$(WL_NAMESPACE)" "cluster/$(WL_CLUSTER_NAME)" -o jsonpath='{.metadata.annotations.test-bed/revision-description}' 2>/dev/null || true)"
	@echo
	@{ \
		$(CLUSTER_KUBECTL) get dockermachines.v1beta1.infrastructure.cluster.x-k8s.io -n "$(WL_NAMESPACE)" -o jsonpath='{range .items[*]}I$(OVERVIEW_TAB){.metadata.name}$(OVERVIEW_TAB){.metadata.labels.test-bed/infra}$(OVERVIEW_TAB){.spec.customImage}$(OVERVIEW_NL){end}'; \
		$(CLUSTER_KUBECTL) get kubeadmconfigs.v1beta1.bootstrap.cluster.x-k8s.io -n "$(WL_NAMESPACE)" -o jsonpath='{range .items[*]}B$(OVERVIEW_TAB){.metadata.name}$(OVERVIEW_TAB){.metadata.labels.test-bed/bootstrap}$(OVERVIEW_NL){end}'; \
		$(CLUSTER_KUBECTL) get machines.v1beta1.cluster.x-k8s.io -n "$(WL_NAMESPACE)" -l node.cluster.x-k8s.io/karpenter-member -o jsonpath='{range .items[*]}K$(OVERVIEW_TAB){.metadata.name}$(OVERVIEW_NL){end}'; \
		$(WL_KUBECTL) get nodes -o jsonpath='{range .items[*]}N$(OVERVIEW_TAB){.metadata.name}$(OVERVIEW_TAB){.status.conditions[?(@.type=="Ready")].status}$(OVERVIEW_TAB){.status.nodeInfo.kubeletVersion}$(OVERVIEW_NL){end}'; \
		$(WL_KUBECTL) get nodeclaims -o jsonpath='{range .items[*]}C$(OVERVIEW_TAB){.status.nodeName}$(OVERVIEW_TAB){.metadata.name}$(OVERVIEW_NL){end}'; \
		$(CLUSTER_KUBECTL) get machines.v1beta1.cluster.x-k8s.io -n "$(WL_NAMESPACE)" -o jsonpath='{range .items[*]}M$(OVERVIEW_TAB){.metadata.name}$(OVERVIEW_TAB){.metadata.labels.cluster\.x-k8s\.io/set-name}$(OVERVIEW_TAB){.status.phase}$(OVERVIEW_TAB){.metadata.deletionTimestamp}$(OVERVIEW_TAB){.spec.version}$(OVERVIEW_TAB){.spec.infrastructureRef.name}$(OVERVIEW_TAB){.spec.bootstrap.configRef.name}$(OVERVIEW_TAB){.status.nodeRef.name}$(OVERVIEW_NL){end}'; \
	} 2>/dev/null | awk -F'\t' ' \
		function or(v) { return v == "" ? "-" : v } \
		$$1 == "I" { infra[$$2] = $$3; image[$$2] = $$4; sub(/@.*/, "", image[$$2]); sub(/.*:/, "", image[$$2]); next } \
		$$1 == "B" { boot[$$2] = $$3; next } \
		$$1 == "K" { member[$$2] = 1; next } \
		$$1 == "N" { ready[$$2] = ($$3 == "True" ? "Ready" : "NotReady"); kubelet[$$2] = $$4; next } \
		$$1 == "C" { if ($$2 == "") pending = pending " " $$3; else claim[$$2] = $$3; next } \
		$$1 == "M" { rows[++r] = sprintf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", $$2, \
			($$3 == "" ? "control-plane" : $$3), ($$5 != "" ? "Deleting" : or($$4)), or($$6), \
			or(infra[$$7]), or(image[$$7]), or(boot[$$8]), or($$9), or(ready[$$9]), or(kubelet[$$9]), or(claim[$$9]), ($$2 in member ? "yes" : "-")) } \
		END { \
			print "MACHINE\tMACHINESET\tPHASE\tVERSION\tINFRA\tIMAGE\tBOOTSTRAP\tNODE\tNODE-STATUS\tKUBELET\tNODECLAIM\tKARPENTER"; \
			for (i = 1; i <= r; i++) print rows[i]; \
			if (pending != "") print "\nNodeClaims without a Node:" pending; \
		}' | column -t -s $$'\t'

##@ Issues

# One folder per issue under issues/, named after its number, holding a
# replicate.sh and a README.md. `make replicate-issue-<N>` runs issues/<N>/.
ISSUES_DIR := issues
ISSUES     := $(sort $(notdir $(patsubst %/,%,$(wildcard $(ISSUES_DIR)/*/))))

.PHONY: list-issues
list-issues: ## List the issues with a reproduction under issues/
	@printf '%s\n' $(ISSUES)

# Builds the clusters first when they are not up (no workload kubeconfig yet),
# then releases the current commit into Karpenter, so a run always tests the
# code on the branch. The script itself refuses a cluster that is not at its
# starting revision.
replicate-issue-%: install-kubectl install-yq ## Reproduce issue % with issues/%/replicate.sh; evidence in issues/%/runs/
	@test -x "$(ISSUES_DIR)/$*/replicate.sh" || { echo "Error: no $(ISSUES_DIR)/$*/replicate.sh. Issues: $(ISSUES)"; exit 1; }
	@test -f "$(WL_KUBECONFIG)" || $(MAKE) --no-print-directory clusters
	@$(MAKE) --no-print-directory karpenter-release
	$(ISSUES_DIR)/$*/replicate.sh

##@ Karpenter

.PHONY: karpenter-chart
karpenter-chart: ## Copy the provider's Helm chart from KARPENTER_REPO into the kustomization's chart cache
	@test -f "$(KARPENTER_CHART)/Chart.yaml" || { echo "Error: no chart at $(KARPENTER_CHART). Set KARPENTER_REPO."; exit 1; }
	@rm -rf "$(KARPENTER_CHART_CACHE)/karpenter" && mkdir -p "$(KARPENTER_CHART_CACHE)" && cp -R "$(KARPENTER_CHART)" "$(KARPENTER_CHART_CACHE)/karpenter"
	@echo "✅ chart cached from $(KARPENTER_CHART)"

# CAPD nodes are not a kind cluster, so there is no `kind load`; the image is
# streamed into the control plane node's containerd. Karpenter-made workers
# never get it, which is why the chart values pin the pod to the control plane.
.PHONY: karpenter-image
karpenter-image: karpenter-build karpenter-set-image karpenter-import ## Build the current commit, point components/karpenter-image at it and import it (no deploy)

# Builds only when the tag is not there yet: a tag names one commit and one set
# of uncommitted changes, so an existing image is already this build. Needs the
# network: BuildKit resolves the base image's metadata on Docker Hub even when
# its layers are cached.
.PHONY: karpenter-build
karpenter-build: check-docker ## Build the provider image from KARPENTER_REPO, tagged with its commit
	@test -f "$(KARPENTER_REPO)/go.mod" || { echo "Error: no provider checkout at $(KARPENTER_REPO). Set KARPENTER_REPO."; exit 1; }
	@test -n "$(KARPENTER_SHA)" || { echo "Error: $(KARPENTER_REPO) is not a git checkout."; exit 1; }
	@if docker image inspect "$(KARPENTER_IMAGE)" >/dev/null 2>&1; then echo "   $(KARPENTER_IMAGE) already built"; exit 0; fi; \
	docker build --build-arg ARCH="$(ARCH)" --build-arg BUILDER_IMAGE="$(KARPENTER_BUILDER_IMAGE)" \
		-t "$(KARPENTER_IMAGE)" "$(KARPENTER_REPO)"

# Rewrites the component with `kustomize edit set image`; nothing is deployed.
.PHONY: karpenter-set-image
karpenter-set-image: install-kustomize ## Point components/karpenter-image at this build's tag (file only)
	@cd "$(KARPENTER_IMAGE_COMPONENT)" && kustomize edit set image "$(KARPENTER_IMAGE_NAME)=$(KARPENTER_IMAGE)"
	@echo "✅ $(KARPENTER_IMAGE_COMPONENT) -> $(KARPENTER_IMAGE)"

# Offline: streams the image the component names into every running control
# plane node that lacks it. Idempotent and cheap when nothing is missing, so
# `make upgrade` calls it repeatedly while the control plane rolls: a new node
# gets the image as soon as it runs, before Karpenter is evicted from the old
# one.
.PHONY: karpenter-import
karpenter-import: check-docker install-kubectl install-yq cluster-check ## Import the image components/karpenter-image names into every workload control plane node lacking it
	@image=$$($(KARPENTER_DEPLOYED_IMAGE_CMD)); \
	docker image inspect "$$image" >/dev/null 2>&1 || { echo "Error: no local $$image; run 'make karpenter-release'."; exit 1; }; \
	nodes=$$($(CLUSTER_KUBECTL) get machines -n "$(WL_NAMESPACE)" -l cluster.x-k8s.io/cluster-name=$(WL_CLUSTER_NAME),cluster.x-k8s.io/control-plane \
		-o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}'); \
	[ -n "$$nodes" ] || { echo "Error: no running $(WL_CLUSTER_NAME) control plane Machine; has 'make management' run?"; exit 1; }; \
	for node in $$nodes; do \
		if docker exec "$$node" crictl inspecti "$$image" >/dev/null 2>&1; then \
			echo "   $$image already on $$node"; \
		else \
			docker save "$$image" | docker exec -i "$$node" ctr -n k8s.io images import - >/dev/null; \
			echo "✅ $$image imported into $$node"; \
		fi; \
	done

# Builds the current commit of the provider checkout, points the component at
# it and applies the add-ons: the new tag changes the Deployment, so
# Kubernetes replaces the pod. Releasing an unchanged commit changes nothing.
.PHONY: karpenter-release
karpenter-release: install-kustomize install-helm install-kubectl wl-check karpenter-chart karpenter-image ## Deploy Karpenter built from the current commit of the provider checkout
	$(call apply-converged,$(ADDONS_OVERLAY),kustomize build --enable-helm $(ADDONS_OVERLAY),$(WL_KUBECTL))
	@$(WL_KUBECTL) rollout status -n "$(KARPENTER_NAMESPACE)" deployment/karpenter --timeout="$(DEPLOY_WAIT_TIMEOUT)"
	@$(MAKE) -s --no-print-directory karpenter-check

.PHONY: karpenter-restart
karpenter-restart: install-kubectl wl-check ## Restart Karpenter and wait for it
	$(WL_KUBECTL) rollout restart -n "$(KARPENTER_NAMESPACE)" deployment/karpenter
	$(WL_KUBECTL) rollout status -n "$(KARPENTER_NAMESPACE)" deployment/karpenter --timeout="$(DEPLOY_WAIT_TIMEOUT)"

# Compares the running pods' image with the one components/karpenter-image
# names; pods already being deleted after a rollout are skipped. The last line
# of output is the verdict.
.PHONY: karpenter-check
karpenter-check: install-kubectl install-yq wl-check ## Check Karpenter runs the image components/karpenter-image names (exit 1 if not)
	@want=$$($(KARPENTER_DEPLOYED_IMAGE_CMD)); \
	images=$$($(WL_KUBECTL) get pods -n "$(KARPENTER_NAMESPACE)" -l app.kubernetes.io/name=karpenter --field-selector=status.phase=Running \
		-o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{(index .spec.containers 0).image}}{{"\n"}}{{end}}{{end}}' 2>/dev/null | sort -u | paste -sd' ' -); \
	if [ "$$images" = "$$want" ]; then \
		echo "Karpenter runs $$want, as components/karpenter-image names"; \
	else \
		echo "Karpenter runs $${images:-no pod}, not $$want as components/karpenter-image names; run 'make karpenter-release'"; exit 1; \
	fi

.PHONY: karpenter-logs
karpenter-logs: install-kubectl wl-check ## Follow the Karpenter controller log
	$(WL_KUBECTL) logs -n "$(KARPENTER_NAMESPACE)" deployment/karpenter -f


##@ Workloads

.PHONY: workloads
workloads: install-kustomize install-kubectl install-yq wl-check ## Apply the test apps overlay (SCALE_UP_REPLICAS overrides its replica count)
	$(call apply-converged,$(WORKLOADS_OVERLAY),kustomize build $(WORKLOADS_OVERLAY)$(if $(SCALE_UP_REPLICAS), | N="$(SCALE_UP_REPLICAS)" yq '(select(.kind == "Deployment" and .metadata.name == "$(SCALE_UP_DEPLOYMENT)") | .spec.replicas) = (strenv(N) | tonumber)'),$(WL_KUBECTL))
	@echo "✅ $(SCALE_UP_DEPLOYMENT) at $$($(WL_KUBECTL) get deployment "$(SCALE_UP_DEPLOYMENT)" -o jsonpath='{.spec.replicas}') replica(s); run 'make watch'"

.PHONY: workloads-down
workloads-down: ## Apply the test apps overlay at zero replicas so Karpenter removes their nodes
	@$(MAKE) --no-print-directory workloads SCALE_UP_REPLICAS=0

.PHONY: watch
watch: install-kubectl cluster-check ## Redraw the overview table every WATCH_INTERVAL seconds (Ctrl-C to stop)
	@while true; do out=$$($(MAKE) --no-print-directory -s overview 2>&1 | grep -v ' ready$$'); clear; date '+%T'; echo "$$out"; sleep $(WATCH_INTERVAL); done

# Print a composite's manifests without touching any cluster.
.PHONY: render render-addons render-workloads
render: install-kustomize install-helm ## Render the management overlay at the revision it names (`make set-revision REVISION=<NN-…> render` for another)
	@kustomize build --enable-helm "$(MANAGEMENT_OVERLAY)"
render-addons: install-kustomize install-helm karpenter-chart ## Render the workload cluster's add-ons to stdout
	@kustomize build --enable-helm "$(ADDONS_OVERLAY)"
render-workloads: install-kustomize ## Render the test apps overlay to stdout
	@kustomize build "$(WORKLOADS_OVERLAY)"

##@ Observability

.PHONY: status
status: install-kubectl cluster-check ## Show nodes, baseline pods, and the operator's webhook certificate
	@echo "--- nodes ---"
	@$(CLUSTER_KUBECTL) get nodes -o wide
	@echo
	@echo "--- cert-manager ---"
	@$(CLUSTER_KUBECTL) get pods -n cert-manager 2>/dev/null || echo "(not deployed)"
	@echo
	@echo "--- capi-operator-system ---"
	@$(CLUSTER_KUBECTL) get pods,certificate,issuer -n capi-operator-system 2>/dev/null || echo "(not deployed)"
	@echo
	@echo "--- workload cluster: $(WL_CLUSTER_NAME) ---"
	@$(MAKE) --no-print-directory -s overview 2>/dev/null || echo "(not created)"
	@test -f "$(WL_KUBECONFIG)" && $(WL_KUBECTL) get pods -n "$(KARPENTER_NAMESPACE)" 2>/dev/null || true


##@ Cleanup

.PHONY: down
down: wl-down cluster-down ## Delete the workload cluster, then the kind cluster
	@echo "✅ Environment down."

.PHONY: clean
clean: clean-tools ## Remove tools, chart caches and kubeconfigs (clusters are left alone)
	@rm -rf "$(KUBECONFIG_DIR)" $(CLUSTERS_DIR)/management/*/charts $(CLUSTERS_DIR)/karpenter-docker/addons/*/charts
	@echo "✅ Clean."

.PHONY: clean-tools
clean-tools: ## Remove installed tool binaries and their caches
	@echo "Removing installed tools in $(TOOLS_BIN_DIR)..."
	@rm -rf $(TOOLS_BIN_DIR) $(TOOLS_DIR)/cache


##@ Tool Installations

# Each tool declaration registers itself with TOOLS += <name>.

.PHONY: tools
tools: $(addprefix install-,$(TOOLS)) ## Install every tool in TOOLS

.PHONY: tools-list
tools-list: ## List the installable tools and their pinned versions
	@for t in $(TOOLS); do \
		version_variable=$$(printf '%s_VER' "$$t" | tr 'a-z-' 'A-Z_'); \
		printf "  %-12s %s\n" "$$t" "$${!version_variable}"; \
	done

install-%: ## Install a specific tool (see `make tools-list`)
	@echo "$(TOOLS)" | grep -qw "$*" || { echo "Error: unknown tool '$*'. Run 'make tools-list'."; exit 1; }

# Internal: print an exported setting by name (via the environment, so pipes print literally).
print-%:
	@printf '%s\n' "$${$*}"

# $(call tool-rules,NAME,UPPERCASE_NAME) - the install-<tool> target and download
# rule for one tool, generated for every entry in TOOLS.
define tool-rules
.PHONY: install-$(1)
install-$(1): $$($(2))
	@ln -sfn "$(1)-$$($(2)_VER)" "$$(TOOLS_BIN_DIR)/$(1)"
	@echo "✅ $(1) $$($(2)_VER) ready"

$$($(2)):
	$$(call download-binary,$$($(2)),$$($(2)_BIN),$$($(2)_VER),$$($(2)_URL),$$($(2)_CHECKSUM_URL),$$($(2)_TAR_PATH),$$($(2)_CHECKSUM_FIELD))
	@echo "   $$($(2)_BIN) $$($(2)_VER) -> $$($(2))"
endef

$(foreach t,$(TOOLS),$(eval $(call tool-rules,$(t),$(shell echo $(t) | tr 'a-z-' 'A-Z_'))))


# ------------------------------------------------------------------------------
# Pre-Flight Checks (verify, never change)
# ------------------------------------------------------------------------------

##@ Pre-Flight Checks

.PHONY: check-docker
check-docker: ## Verify Docker is available and running (kind needs it)
	@command -v docker >/dev/null 2>&1 || { echo "Error: Docker is required but not installed"; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "Error: Docker daemon is not running"; exit 1; }

# Internal guard: the kubeconfig must exist before a target can use it.
.PHONY: cluster-check
cluster-check:
	@test -f "$(CLUSTER_KUBECONFIG)" || { echo "Error: no kubeconfig at $(CLUSTER_KUBECONFIG). Run 'make cluster-kind'."; exit 1; }

.PHONY: wl-check
wl-check:
	@test -f "$(WL_KUBECONFIG)" || { echo "Error: no workload kubeconfig at $(WL_KUBECONFIG). Run 'make wl-kubeconfig'."; exit 1; }

.PHONY: check-tools
check-tools: ## Check for upstream version updates for all tools
	@$(foreach t,$(TOOL_DEFS),\
		$(call tool-version-check,$($(t)_BIN),$($(t)_VER),$($(t)_LATEST_CMD))$(newline))

define newline


endef

# $(call tool-version-check,BINARY_NAME,CURRENT_VERSION,LATEST_VERSION_CMD)
define tool-version-check
	$(if $(strip $(3)),\
	if latest="$$($(3))" && [ -n "$$latest" ]; then \
		if [ "$$latest" != "$(2)" ]; then \
			echo "ℹ️  New version available for $(1): current $(2) -> latest $$latest"; \
		fi; \
	else \
		echo "Warning: could not check the latest $(1) version; keeping $(2)." >&2; \
	fi,\
	printf '%s\n' 'Skipping $(1): no release URL configured.')
endef


# ------------------------------------------------------------------------------
# Helpers (internal macros, not targets)
# ------------------------------------------------------------------------------

# $(call download-binary,BINARY_PATH,BINARY_NAME,VERSION,URL,CHECKSUM_URL,FILE_IN_TAR,CHECKSUM_FIELD)
# Downloads, verifies (CHECKSUM_FIELD selects a column for multi-hash files),
# extracts in a temp dir and publishes the binary only when every step passed.
define download-binary
	@echo "Downloading $(2) $(3)..."; \
	mkdir -p "$(TOOLS_BIN_DIR)"; \
	install_directory=$$(mktemp -d "$(TOOLS_BIN_DIR)/.$(2).XXXXXX"); \
	trap 'rm -rf "$$install_directory"' EXIT; \
	trap 'exit 130' INT; \
	trap 'exit 143' TERM; \
	trap 'exit 129' HUP; \
	curl -fsSL --connect-timeout 10 --max-time 300 \
		-o "$$install_directory/download" "$(4)"; \
	if [ -n "$(5)" ]; then \
		curl -fsSL --connect-timeout 10 --max-time 60 \
			-o "$$install_directory/checksums" "$(5)"; \
		if [ -n "$(7)" ]; then \
			expected_checksum=$$(awk -v asset="$$(basename "$(4)")" -v col="$(7)" \
				'$$1 == asset { print $$col; exit }' \
				"$$install_directory/checksums" | tr 'A-F' 'a-f'); \
		else \
			expected_checksum=$$(awk -v asset="$$(basename "$(4)")" \
				'NF == 1 || (NF == 2 && ($$2 == asset || $$2 == "*" asset)) { print $$1 }' \
				"$$install_directory/checksums" | tr 'A-F' 'a-f'); \
		fi; \
		if [[ ! "$$expected_checksum" =~ ^[[:xdigit:]]{64}$$ ]]; then \
			echo "Error: missing or ambiguous SHA-256 checksum for $(2)." >&2; \
			exit 1; \
		fi; \
		if command -v sha256sum >/dev/null 2>&1; then \
			checksum_command=(sha256sum); \
		else \
			checksum_command=(shasum -a 256); \
		fi; \
		actual_checksum=$$("$${checksum_command[@]}" "$$install_directory/download" | awk '{print $$1}'); \
		if [ "$$actual_checksum" != "$$expected_checksum" ]; then \
			echo "Error: checksum verification failed for $(2)! Computed: $$actual_checksum" >&2; \
			exit 1; \
		fi; \
		echo "✅ $(2) checksum verified ($$actual_checksum)"; \
	else \
		echo "⚠️  $(2) $(3): publisher ships no checksum; skipping verification."; \
	fi; \
	if [[ "$(4)" == *.tar.gz ]]; then \
		tar -xzf "$$install_directory/download" -O "$(6)" > "$$install_directory/binary"; \
	else \
		mv "$$install_directory/download" "$$install_directory/binary"; \
	fi; \
	test -s "$$install_directory/binary"; \
	chmod +x "$$install_directory/binary"; \
	mv -f "$$install_directory/binary" "$(1)"
endef
