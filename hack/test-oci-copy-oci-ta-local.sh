#!/bin/bash

# hack/test-oci-copy-oci-ta-local.sh
# Script to run oci-copy-oci-ta tests locally using Kind, Konflux-CI, and a local OCI registry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KONFLUX_CI_DIR="${REPO_ROOT}/konflux-ci" # Path to clone konflux-ci
OCI_COPY_TASK_DIR="${REPO_ROOT}/task/oci-copy-oci-ta/0.2"
# TEST_NAMESPACE="oci-copy-ta-0-2-testns" # Namespace will be derived by test_tekton_tasks.sh

# Default Kind cluster name, can be overridden
KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-"konflux-test"}

# Test Pipeline/TaskRun YAML files
PIPELINE_FILE_TRANSFER_SUCCESS_YAML="${OCI_COPY_TASK_DIR}/tests/test-oci-copy-oci-ta-success.yaml"
PIPELINE_FILE_TRANSFER_FAILURE_YAML="${OCI_COPY_TASK_DIR}/tests/test-oci-copy-oci-ta-missing-file.yaml"
PIPELINE_HTTPS_TRANSFER_SUCCESS_YAML="${OCI_COPY_TASK_DIR}/tests/test-oci-copy-oci-ta-https-success.yaml"
PIPELINE_HTTPS_TRANSFER_FAILURE_YAML="${OCI_COPY_TASK_DIR}/tests/test-oci-copy-oci-ta-https-unavailable.yaml"

# Konflux-CI Git repository and ref
KONFLUX_CI_REPO=${KONFLUX_CI_REPO:-"https://github.com/konflux-ci/konflux-ci.git"}
# Use the specific ref from .github/workflows/run-task-tests.yaml for stability
KONFLUX_CI_REF=${KONFLUX_CI_REF:-"3b100fc207b9ce22abf045634b3fb3584a6a6b5f"}

# Helper functions
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; exit 1; }

cleanup_pipelines() {
  info "Cleaning up temporary pipeline YAML modifications..."
  # Define them here again or pass as arguments if preferred
  local PIPELINE_FILE_SUCCESS_YAML_PATH="${OCI_COPY_TASK_DIR}/tests/test-oci-copy-oci-ta-success.yaml"
  local PIPELINE_FILE_FAILURE_YAML_PATH="${OCI_COPY_TASK_DIR}/tests/test-oci-copy-oci-ta-missing-file.yaml"
  local PIPELINE_HTTPS_SUCCESS_YAML_PATH="${OCI_COPY_TASK_DIR}/tests/test-oci-copy-oci-ta-https-success.yaml"
  local PIPELINE_HTTPS_FAILURE_YAML_PATH="${OCI_COPY_TASK_DIR}/tests/test-oci-copy-oci-ta-https-unavailable.yaml"

  for yaml_file in \
    "${PIPELINE_FILE_SUCCESS_YAML_PATH}" \
    "${PIPELINE_FILE_FAILURE_YAML_PATH}" \
    "${PIPELINE_HTTPS_SUCCESS_YAML_PATH}" \
    "${PIPELINE_HTTPS_FAILURE_YAML_PATH}"; \
  do
    if [ -f "${yaml_file}.bak" ]; then
      mv "${yaml_file}.bak" "${yaml_file}"
      info "Restored ${yaml_file}"
    fi
  done
}

cleanup_exit() {
  cleanup_pipelines
  info "Local test script finished."
  # Add kind cluster deletion here if desired, e.g.:
  # info "To delete the Kind cluster, run: kind delete cluster --name ${KIND_CLUSTER_NAME}"
}
trap cleanup_exit EXIT

check_deps() {
  info "Checking dependencies..."
  command -v kind >/dev/null 2>&1 || error "kind CLI not found. Please install it."
  command -v kubectl >/dev/null 2>&1 || error "kubectl CLI not found. Please install it."
  command -v tkn >/dev/null 2>&1 || error "tkn CLI (Tekton CLI) not found. Please install it."
  command -v git >/dev/null 2>&1 || error "git CLI not found. Please install it."
  command -v yq >/dev/null 2>&1 || error "yq CLI (version 4+) not found. Please install it."
}

create_kind_cluster() {
  if kind get clusters --quiet | grep -q "^${KIND_CLUSTER_NAME}$"; then
    info "Kind cluster '${KIND_CLUSTER_NAME}' already exists. Using it."
    kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"
    return
  fi

  info "Creating Kind cluster '${KIND_CLUSTER_NAME}'..."
  # Ensure KONFLUX_CI_DIR is available for kind-config.yaml
  if [ ! -d "${KONFLUX_CI_DIR}" ]; then
    clone_konflux_ci # Clone if not present, as kind-config.yaml is needed
  fi

  if [ -f "${KONFLUX_CI_DIR}/kind-config.yaml" ]; then
    kind create cluster --name "${KIND_CLUSTER_NAME}" --config "${KONFLUX_CI_DIR}/kind-config.yaml" --wait 5m
  else
    warn "konflux-ci/kind-config.yaml not found at ${KONFLUX_CI_DIR}/kind-config.yaml. Creating Kind cluster with defaults."
    kind create cluster --name "${KIND_CLUSTER_NAME}" --wait 5m
  fi
  kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"
}

clone_konflux_ci() {
  if [ -d "${KONFLUX_CI_DIR}" ] && [ -d "${KONFLUX_CI_DIR}/.git" ]; then
    info "Konflux-CI directory '${KONFLUX_CI_DIR}' already exists. Ensuring correct ref..."
    pushd "${KONFLUX_CI_DIR}" >/dev/null
    git fetch --all --tags # Fetch tags to ensure the ref can be checked out
    git checkout "${KONFLUX_CI_REF}"
    popd >/dev/null
    return
  fi
  info "Cloning Konflux-CI from ${KONFLUX_CI_REPO} (ref: ${KONFLUX_CI_REF}) into ${KONFLUX_CI_DIR}..."
  rm -rf "${KONFLUX_CI_DIR}" # Remove if it's not a git repo
  git clone --branch "${KONFLUX_CI_REF}" "${KONFLUX_CI_REPO}" "${KONFLUX_CI_DIR}"
}

deploy_konflux_ci_stack() {
  info "Deploying Konflux-CI stack (dependencies, Tekton, Konflux)..."
  pushd "${KONFLUX_CI_DIR}" >/dev/null

  # Check if Tekton is already installed (basic check)
  if kubectl get crd pipelineruns.tekton.dev >/dev/null 2>&1; then
    info "Tekton (pipelineruns.tekton.dev CRD) seems to be already installed. Skipping ./deploy-deps.sh and ./deploy-konflux.sh parts related to Tekton."
  else
    info "Running ./deploy-deps.sh (installs Tekton Operator, etc.)"
    ./deploy-deps.sh || error "Failed to deploy dependencies."
    info "Running ./wait-for-all.sh (waits for Tekton Operator, etc.)"
    ./wait-for-all.sh || error "Timed out waiting for dependencies."
    info "Running ./deploy-konflux.sh (deploys Tekton Pipelines, Triggers, Dashboard from Operator)"
    ./deploy-konflux.sh || error "Failed to deploy Konflux (Tekton components)."
  fi

  info "Running ./deploy-test-resources.sh (deploys other Konflux test resources)"
  if [ -f "./deploy-test-resources.sh" ]; then
    info "Running ./deploy-test-resources.sh..."
    ./deploy-test-resources.sh || warn "Failed to deploy test resources (some errors might be ignorable if resources already exist)."
  else
    warn "./deploy-test-resources.sh not found in ${KONFLUX_CI_DIR}. Skipping."
  fi

  popd >/dev/null
  info "Konflux-CI stack deployment attempt complete."
}

deploy_local_oci_registry() {
  local target_ns="$1"
  info "Deploying local OCI registry to namespace '${target_ns}'..."

  if ! kubectl get namespace "${target_ns}" >/dev/null 2>&1; then
    kubectl create namespace "${target_ns}" || error "Failed to create namespace ${target_ns}"
  fi

  REGISTRY_DEPLOYMENT_YAML="${OCI_COPY_TASK_DIR}/tests/data/mock-registry/registry-deployment.yaml"
  if [ ! -f "$REGISTRY_DEPLOYMENT_YAML" ]; then
    error "Registry deployment YAML not found at $REGISTRY_DEPLOYMENT_YAML"
  fi

  info "Applying registry deployment from $REGISTRY_DEPLOYMENT_YAML to ${target_ns}..."
  kubectl apply -f "$REGISTRY_DEPLOYMENT_YAML" -n "${target_ns}"

  info "Waiting for local OCI registry deployment to be ready in ${target_ns}..."
  kubectl wait --for=condition=available deployment/oci-registry -n "${target_ns}" --timeout=180s     || error "Local OCI registry deployment timed out in ${target_ns}."

  info "Local OCI registry deployed successfully in ${target_ns}."
  info "It should be accessible within the cluster at oci-registry-service.${target_ns}.svc.cluster.local:5000"
}

deploy_local_http_server() {
  local target_ns="$1"
  info "Deploying local HTTP server to namespace '${target_ns}'..."

  if ! kubectl get namespace "${target_ns}" >/dev/null 2>&1; then
    kubectl create namespace "${target_ns}" || error "Failed to create namespace ${target_ns}"
  fi

  HTTP_SERVER_CONFIGMAP_YAML="${OCI_COPY_TASK_DIR}/tests/data/mock-http-server/http-server-configmap.yaml"
  HTTP_SERVER_DEPLOYMENT_YAML="${OCI_COPY_TASK_DIR}/tests/data/mock-http-server/http-server-deployment.yaml"

  if [ ! -f "$HTTP_SERVER_CONFIGMAP_YAML" ]; then
    error "HTTP server ConfigMap YAML not found at $HTTP_SERVER_CONFIGMAP_YAML"
  fi
  if [ ! -f "$HTTP_SERVER_DEPLOYMENT_YAML" ]; then
    error "HTTP server Deployment YAML not found at $HTTP_SERVER_DEPLOYMENT_YAML"
  fi

  info "Applying HTTP server ConfigMap from $HTTP_SERVER_CONFIGMAP_YAML to ${target_ns}..."
  kubectl apply -f "$HTTP_SERVER_CONFIGMAP_YAML" -n "${target_ns}"
  info "Applying HTTP server Deployment from $HTTP_SERVER_DEPLOYMENT_YAML to ${target_ns}..."
  kubectl apply -f "$HTTP_SERVER_DEPLOYMENT_YAML" -n "${target_ns}"

  info "Waiting for local HTTP server deployment to be ready in ${target_ns}..."
  kubectl wait --for=condition=available deployment/http-server -n "${target_ns}" --timeout=180s || error "Local HTTP server deployment timed out in ${target_ns}."

  info "Local HTTP server deployed successfully in ${target_ns}."
  info "It should be accessible within the cluster at http-server-service.${target_ns}.svc.cluster.local:8080"
}


run_oci_copy_tests() {
  info "Running oci-copy-oci-ta tests using .github/scripts/test_tekton_tasks.sh..."

  TASK_NAME_FOR_NS="oci-copy-oci-ta"
  TASK_VERSION_FOR_NS="0-2" # from 0.2, dots replaced by hyphens
  DERIVED_TEST_NS="${TASK_NAME_FOR_NS}-${TASK_VERSION_FOR_NS}" # Example: oci-copy-oci-ta-0-2

  info "Tests will run in namespace: ${DERIVED_TEST_NS}, which will be created by test_tekton_tasks.sh."

  info "Deploying local OCI registry to the test namespace: ${DERIVED_TEST_NS}"
  deploy_local_oci_registry "${DERIVED_TEST_NS}"

  info "Deploying local HTTP server to the test namespace: ${DERIVED_TEST_NS}"
  deploy_local_http_server "${DERIVED_TEST_NS}" # For HTTPS tests

  # Define paths to all relevant pipeline/taskrun YAMLs using the global vars
  declare -A TEST_PIPELINES
  TEST_PIPELINES["FILE_SUCCESS"]="${PIPELINE_FILE_TRANSFER_SUCCESS_YAML}"
  TEST_PIPELINES["FILE_FAILURE"]="${PIPELINE_FILE_TRANSFER_FAILURE_YAML}"
  TEST_PIPELINES["HTTPS_SUCCESS"]="${PIPELINE_HTTPS_TRANSFER_SUCCESS_YAML}"
  TEST_PIPELINES["HTTPS_FAILURE"]="${PIPELINE_HTTPS_TRANSFER_FAILURE_YAML}"

  info "Temporarily patching test pipeline YAMLs to set default for targetNamespace to ${DERIVED_TEST_NS}..."
  for key in "${!TEST_PIPELINES[@]}"; do
    local yaml_file="${TEST_PIPELINES[$key]}"
    if [ -f "${yaml_file}" ]; then
      info "Processing ${yaml_file} for targetNamespace patching..."
      cp "${yaml_file}" "${yaml_file}.bak"

      if yq -e '.kind == "Pipeline"' "${yaml_file}" >/dev/null; then
        # Patch 'targetNamespace' param if it exists in a Pipeline
        if yq -e '.spec.params[] | select(.name == "targetNamespace")' "${yaml_file}" > /dev/null; then
          yq -i ".spec.params[] |= (select(.name == "targetNamespace").default = "${DERIVED_TEST_NS}")" "${yaml_file}"
          info "Patched Pipeline ${yaml_file}. Verifying patch:"
          yq ".spec.params[] | select(.name == "targetNamespace")" "${yaml_file}"
        else
          info "Pipeline ${yaml_file} does not have a 'targetNamespace' parameter. Skipping patching for it."
        fi
      elif yq -e '.kind == "TaskRun"' "${yaml_file}" >/dev/null; then
        info "Skipping targetNamespace patching for TaskRun ${yaml_file} as it's applied directly to the derived namespace by test_tekton_tasks.sh."
      else
        warn "Unknown kind in ${yaml_file}. Cannot determine how to patch targetNamespace."
      fi
    else
      warn "Test YAML ${yaml_file} (key: $key) not found. Skipping patching."
    fi
  done

  pushd "${REPO_ROOT}" >/dev/null
  info "Executing: ./.github/scripts/test_tekton_tasks.sh ${OCI_COPY_TASK_DIR}"
  if ./.github/scripts/test_tekton_tasks.sh "${OCI_COPY_TASK_DIR}"; then
    info "oci-copy-oci-ta tests PASSED."
  else
    # Capture logs from pipelinerun if it failed
    PR_LOG_PATH="${REPO_ROOT}/pipelinerun-logs-${DERIVED_TEST_NS}.txt"
    info "Attempting to capture PipelineRun logs to ${PR_LOG_PATH}"
    # This assumes only one PR was created by the script in that namespace recently.
    # A more robust way would be to get the PR name from test_tekton_tasks.sh output if possible.
    LATEST_PR=$(kubectl get pipelineruns -n "${DERIVED_TEST_NS}" -o jsonpath='{.items[?(@.status.startTime)].metadata.name}' --sort-by=.status.startTime | tail -n 1)
    if [ -n "$LATEST_PR" ]; then
        info "Capturing logs for PipelineRun: $LATEST_PR in namespace ${DERIVED_TEST_NS}"
        tkn pipelinerun logs "$LATEST_PR" -n "${DERIVED_TEST_NS}" > "${PR_LOG_PATH}" 2>&1 || warn "Failed to capture logs for $LATEST_PR"
    else
        warn "Could not determine the latest PipelineRun in ${DERIVED_TEST_NS} to capture logs."
    fi
    error "oci-copy-oci-ta tests FAILED. Check logs above and in ${PR_LOG_PATH} if captured."
  fi
  popd >/dev/null
}

# Main execution
check_deps
clone_konflux_ci
create_kind_cluster # Ensures Kind is running and configured as per konflux-ci
deploy_konflux_ci_stack # Ensures Tekton and other Konflux items are deployed

run_oci_copy_tests

info "Local test script for oci-copy-oci-ta completed successfully."
