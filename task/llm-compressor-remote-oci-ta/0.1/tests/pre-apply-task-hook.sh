#!/bin/bash

# This script is called before applying the task to set up required resources
TASK_COPY="$1"
TEST_NS="$2"

echo "Modifying SSH secret name for testing (localhost mode)"
# Replace dynamic secret name with static one for testing
yq -i eval '.spec.volumes[] |= (select(.name == "ssh").secret.secretName = "test-ssh-secret")' "$TASK_COPY"

echo "Creating SSH secret with host=localhost for in-cluster testing"
kubectl create secret generic test-ssh-secret \
  --from-literal=host=localhost \
  -n "$TEST_NS" --dry-run=client -o yaml | kubectl apply -f - -n "$TEST_NS"

echo "Pre-requirements setup complete"
