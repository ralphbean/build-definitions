#!/bin/bash
# pre-apply-task-hook.sh
# This script is intended to be used as a pre-apply hook for OpenShift GitOps (ArgoCD)
# or a similar CD system when deploying Tekton TaskRuns for testing the oci-copy-oci-ta task.
#
# What it does:
# 1. Sets the TARGET_NAMESPACE environment variable, defaulting to "default" if not provided.
# 2. Creates a PersistentVolumeClaim (PVC) named 'source-pvc' in the target namespace.
#    This PVC will be used by TaskRuns to access source artifacts.
#    It first checks if the PVC already exists to avoid errors.
# 3. Populates the 'source-pvc' with necessary test data:
#    - Creates 'source-data/README.md'
#    - Creates 'source-data/my-app-source.tar.gz' (a small dummy tarball)
#    - Creates 'source-data/oci-copy.yaml' (manifest for successful run)
#    - Creates 'source-data/oci-copy-missing-file.yaml' (manifest for missing file run)
#    This is achieved by running a temporary pod that mounts the PVC and writes the files.
# 4. Deploys a mock OCI registry using 'tests/data/mock-registry/registry-deployment.yaml'.
#    It first checks if the Deployment 'oci-registry' already exists.
#
# How to use:
# - Ensure this script is executable (`chmod +x pre-apply-task-hook.sh`).
# - Configure your GitOps tool to run this script before applying TaskRun YAMLs.
# - Make sure `kubectl` is available and configured to access your cluster.
# - The script expects 'tests/data/mock-registry/registry-deployment.yaml' and
#   the content for the source files to be available relative to its execution path,
#   or adjust paths accordingly.

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error when substituting.
set -o pipefail # Return value of a pipeline is the value of the last command to exit with a non-zero status

# 1. Determine Target Namespace
TARGET_NAMESPACE="${TARGET_NAMESPACE:-default}"
echo "Using target namespace: ${TARGET_NAMESPACE}"

# Path to the mock registry deployment (assuming script is run from task's 0.2/tests/ directory)
# Adjust if your execution context is different.
MOCK_REGISTRY_YAML_PATH="./data/mock-registry/registry-deployment.yaml"
SOURCE_DATA_DIR_IN_PVC="source-data" # Directory inside the PVC where files will be placed

# SHA256 sums pre-calculated for oci-copy.yaml content
# These were calculated in a previous step/subtask.
# For README.md: # Test README\nThis is a test README file for oci-copy-oci-ta.
SHA256_README="bfc4fa58a30a02e9d84eba77df25973af2f97abb246cea76cb5cc07130c37e04"
# For my-app-source.tar.gz (containing app_source_content/main.txt with "Hello World")
SHA256_TAR_GZ="381f3373a9a2044906f097b8c818bd74f72dd12177472f38fa5d302cd874db65"

# 2. Create PersistentVolumeClaim if it doesn't exist
echo "Checking for PVC 'source-pvc' in namespace '${TARGET_NAMESPACE}'..."
if ! kubectl get pvc source-pvc -n "${TARGET_NAMESPACE}" > /dev/null 2>&1; then
  echo "PVC 'source-pvc' not found. Creating..."
  kubectl apply -n "${TARGET_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: source-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Mi # Smallest standard size, adjust if needed
EOF
  echo "PVC 'source-pvc' created."
else
  echo "PVC 'source-pvc' already exists."
fi

# 3. Populate the PVC with test data using a temporary pod
# This approach is more robust than trying to `kubectl cp` into a potentially non-existent pod
# or relying on `kubectl exec` if no suitable pod is running with the PVC.

# Define a unique name for the data population pod
POPULATOR_POD_NAME="pvc-data-populator-$(date +%s)"

echo "Attempting to populate PVC 'source-pvc' via temporary pod '${POPULATOR_POD_NAME}'..."

# Heredoc for the oci-copy.yaml content
OCI_COPY_YAML_CONTENT=$(cat <<EOF
# ${SOURCE_DATA_DIR_IN_PVC}/oci-copy.yaml
artifact_type: "application/vnd.konflux.archive.v1"
artifacts:
  - filename: "my-app-source.tar.gz"
    source: "file://./my-app-source.tar.gz"
    type: "application/gzip"
    sha256sum: "${SHA256_TAR_GZ}"
  - filename: "README.md"
    source: "file://./README.md"
    type: "text/markdown"
    sha256sum: "${SHA256_README}"
EOF
)

# Heredoc for the oci-copy-missing-file.yaml content
OCI_COPY_MISSING_FILE_YAML_CONTENT=$(cat <<EOF
# ${SOURCE_DATA_DIR_IN_PVC}/oci-copy-missing-file.yaml
artifact_type: "application/vnd.konflux.archive.v1"
artifacts:
  - filename: "my-app-source.tar.gz" # This one will exist
    source: "file://./my-app-source.tar.gz"
    type: "application/gzip"
    sha256sum: "${SHA256_TAR_GZ}"
  - filename: "non-existent-file.txt" # This one will NOT exist
    source: "file://./non-existent-file.txt"
    type: "text/plain"
    sha256sum: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" # Dummy SHA
EOF
)

# Create a ConfigMap to hold the content of the files to be copied to the PVC
# This avoids overly complex escaping within the pod's shell command.
CONFIGMAP_NAME="pvc-files-cm-$(date +%s)"
kubectl create configmap "${CONFIGMAP_NAME}" -n "${TARGET_NAMESPACE}" \
  --from-literal=readme_md_content="# Test README\nThis is a test README file for oci-copy-oci-ta." \
  --from-literal=oci_copy_yaml_content="${OCI_COPY_YAML_CONTENT}" \
  --from-literal=oci_copy_missing_yaml_content="${OCI_COPY_MISSING_FILE_YAML_CONTENT}"

# Run a pod to copy files from the ConfigMap and create the tarball in the PVC
# Using busybox for its small size and availability of 'tar' and 'echo'.
# The pod mounts the PVC at /mnt/data and the ConfigMap at /mnt/config.
kubectl run "${POPULATOR_POD_NAME}" \
  --image=busybox:1.36 \
  -n "${TARGET_NAMESPACE}" \
  --restart=Never \
  --overrides='{
    "apiVersion": "v1",
    "spec": {
      "volumes": [
        {
          "name": "source-storage",
          "persistentVolumeClaim": {
            "claimName": "source-pvc"
          }
        },
        {
          "name": "cm-files",
          "configMap": {
            "name": "'"${CONFIGMAP_NAME}"'"
          }
        }
      ],
      "containers": [
        {
          "name": "populator",
          "image": "busybox:1.36",
          "command": ["/bin/sh", "-c"],
          "args": [
            "set -ex; \
            echo 'Creating directory structure in PVC...'; \
            mkdir -p /mnt/data/'"${SOURCE_DATA_DIR_IN_PVC}"'; \
            echo 'Populating README.md from ConfigMap...'; \
            printf \"%s\" \"$(cat /mnt/config/readme_md_content)\" > /mnt/data/'"${SOURCE_DATA_DIR_IN_PVC}"'/README.md; \
            echo 'Populating oci-copy.yaml from ConfigMap...'; \
            printf \"%s\" \"$(cat /mnt/config/oci_copy_yaml_content)\" > /mnt/data/'"${SOURCE_DATA_DIR_IN_PVC}"'/oci-copy.yaml; \
            echo 'Populating oci-copy-missing-file.yaml from ConfigMap...'; \
            printf \"%s\" \"$(cat /mnt/config/oci_copy_missing_yaml_content)\" > /mnt/data/'"${SOURCE_DATA_DIR_IN_PVC}"'/oci-copy-missing-file.yaml; \
            echo 'Creating dummy tarball my-app-source.tar.gz...'; \
            mkdir /tmp/app_source_content; \
            echo \"Hello World\" > /tmp/app_source_content/main.txt; \
            tar -czf /mnt/data/'"${SOURCE_DATA_DIR_IN_PVC}"'/my-app-source.tar.gz -C /tmp/app_source_content .; \
            rm -rf /tmp/app_source_content; \
            echo 'Verifying created files in PVC:'; \
            ls -lR /mnt/data/; \
            echo 'Data population complete.' \
            "
          ],
          "volumeMounts": [
            {
              "name": "source-storage",
              "mountPath": "/mnt/data"
            },
            {
              "name": "cm-files",
              "mountPath": "/mnt/config"
            }
          ]
        }
      ]
    }
  }'

# Wait for the populator pod to complete
echo "Waiting for PVC populator pod '${POPULATOR_POD_NAME}' to complete..."
if kubectl wait --for=condition=Succeeded pod/"${POPULATOR_POD_NAME}" -n "${TARGET_NAMESPACE}" --timeout=120s; then
  echo "PVC populator pod completed successfully."
else
  echo "PVC populator pod did not complete successfully. Logs:"
  kubectl logs pod/"${POPULATOR_POD_NAME}" -n "${TARGET_NAMESPACE}"
  # Attempt to delete the pod and configmap anyway to clean up
  kubectl delete pod "${POPULATOR_POD_NAME}" -n "${TARGET_NAMESPACE}" --ignore-not-found=true
  kubectl delete configmap "${CONFIGMAP_NAME}" -n "${TARGET_NAMESPACE}" --ignore-not-found=true
  exit 1
fi

# Clean up the populator pod and configmap
echo "Cleaning up PVC populator pod and ConfigMap..."
kubectl delete pod "${POPULATOR_POD_NAME}" -n "${TARGET_NAMESPACE}" --ignore-not-found=true
kubectl delete configmap "${CONFIGMAP_NAME}" -n "${TARGET_NAMESPACE}" --ignore-not-found=true
echo "PVC 'source-pvc' populated with test data under '${SOURCE_DATA_DIR_IN_PVC}/'."

# 4. Deploy Mock OCI Registry if it doesn't exist
echo "Checking for mock OCI registry Deployment 'oci-registry' in namespace '${TARGET_NAMESPACE}'..."
if ! kubectl get deployment oci-registry -n "${TARGET_NAMESPACE}" > /dev/null 2>&1; then
  echo "Mock OCI registry Deployment not found. Creating from ${MOCK_REGISTRY_YAML_PATH}..."
  if [ -f "${MOCK_REGISTRY_YAML_PATH}" ]; then
    kubectl apply -n "${TARGET_NAMESPACE}" -f "${MOCK_REGISTRY_YAML_PATH}"
    echo "Mock OCI registry deployed. Waiting for it to be ready..."
    # Wait for the deployment to be available
    kubectl wait --for=condition=available deployment/oci-registry -n "${TARGET_NAMESPACE}" --timeout=120s
    echo "Mock OCI registry is ready."
  else
    echo "Error: Mock registry YAML ${MOCK_REGISTRY_YAML_PATH} not found!"
    # Attempt to clean up PVC if we created it
    # Note: This is a simple cleanup. A more robust script might handle existing PVCs differently.
    # kubectl delete pvc source-pvc -n "${TARGET_NAMESPACE}" --ignore-not-found=true
    exit 1
  fi
else
  echo "Mock OCI registry Deployment 'oci-registry' already exists."
  # Optionally, check if it's ready
  kubectl wait --for=condition=available deployment/oci-registry -n "${TARGET_NAMESPACE}" --timeout=120s --ignore-not-found=true || echo "Warning: Existing registry not ready."
fi

echo "Pre-apply hook script completed successfully."
echo "Prerequisites for oci-copy-oci-ta TaskRuns should now be met in namespace '${TARGET_NAMESPACE}'."
echo " - PVC 'source-pvc' should exist and be populated with:"
echo "   - ${SOURCE_DATA_DIR_IN_PVC}/README.md"
echo "   - ${SOURCE_DATA_DIR_IN_PVC}/my-app-source.tar.gz"
echo "   - ${SOURCE_DATA_DIR_IN_PVC}/oci-copy.yaml"
echo "   - ${SOURCE_DATA_DIR_IN_PVC}/oci-copy-missing-file.yaml"
echo " - Mock OCI registry 'oci-registry' should be running."
