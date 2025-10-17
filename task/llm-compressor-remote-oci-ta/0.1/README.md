# llm-compressor-remote-oci-ta

Remote execution variant of llm-compressor-oci-ta that supports GPU-enabled VMs via multi-platform-controller. Compresses large language models using llm-compressor from the vllm project and pushes the compressed model as an OCI artifact to a container registry.

## Overview

This task extends `llm-compressor-oci-ta` with remote execution capabilities:
- **Remote GPU access** - Execute compression on GPU-enabled VMs provisioned by multi-platform-controller
- **Platform targeting** - Specify target platform (e.g., linux-g/amd64 for GPU)
- **Hermetic execution** - No network access during compression by default
- **Reproducibility** - Dependencies prefetched via hermeto/cachi2
- **Automatic GPU detection** - GPU devices automatically passed through when PLATFORM starts with `linux-g`

## Parameters

All parameters from `llm-compressor-oci-ta` plus:

| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| PLATFORM | Target platform for compression (e.g., "linux-g/amd64" for GPU, "linux/amd64" for CPU) | - | Yes |
| IMAGE_APPEND_PLATFORM | Whether to append sanitized platform to IMAGE tag | "false" | No |

### Base Parameters

| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| SOURCE_ARTIFACT | Trusted artifact URI with compression script and source | - | Yes |
| IMAGE | OCI reference where compressed model will be pushed | - | Yes |
| COMPRESSOR_IMAGE | Container image with llm-compressor installed | - | Yes |
| SCRIPT | Path to compression script relative to source root | - | Yes |
| CACHI2_ARTIFACT | Trusted artifact with prefetched dependencies | "" | No |
| HERMETIC | Execute compression without network access | "true" | No |
| OUTPUT_DIR | Directory where script writes output files | /var/workdir/output | No |
| SBOM_TYPE | SBOM format (spdx or cyclonedx) | spdx | No |
| STORAGE_DRIVER | Buildah storage driver | vfs | No |
| caTrustConfigMapName | ConfigMap name for CA bundle | trusted-ca | No |
| caTrustConfigMapKey | Key in ConfigMap for CA bundle | ca-bundle.crt | No |
| BUILDAH_DEVICES | Device specifications for GPU/accelerator access | [] | No |

## Platform Parameter

The `PLATFORM` parameter determines where compression executes:

### GPU Platforms (linux-g prefix)

Platforms starting with `linux-g` automatically enable GPU pass-through:

```yaml
- name: PLATFORM
  value: "linux-g/amd64"  # GPU-enabled x86_64
```

Automatically adds `--device=nvidia.com/gpu=all` to the compression container.

### CPU Platforms

Standard platforms execute without GPU:

```yaml
- name: PLATFORM
  value: "linux/amd64"    # Standard x86_64
  value: "linux/arm64"    # ARM 64-bit
```

## Multi-Platform Controller Integration

This task requires the multi-platform-controller to provision remote VMs. The controller:

1. Receives the PLATFORM parameter
2. Provisions a VM with the requested platform/GPU
3. Creates SSH credentials in secret `multi-platform-ssh-$(context.taskRun.name)`
4. The task connects via SSH to execute compression remotely

### SSH Secret Structure

The multi-platform-controller creates a secret containing:
- `host` - Hostname/IP of the remote VM
- `id_rsa` - SSH private key for authentication
- `user-dir` - Working directory on remote host

## Usage Example

### 1. Prefetch Dependencies

```yaml
- name: prefetch-dependencies
  params:
    - name: input
      value: |
        {
          "type": "pip",
          "requirements_files": ["requirements.txt"]
        }
    - name: SOURCE_ARTIFACT
      value: $(tasks.clone-repository.results.SOURCE_ARTIFACT)
  taskRef:
    name: prefetch-dependencies-oci-ta
```

### 2. Compress on Remote GPU VM

```yaml
- name: compress-model
  params:
    - name: SOURCE_ARTIFACT
      value: $(tasks.prefetch-dependencies.results.SOURCE_ARTIFACT)
    - name: CACHI2_ARTIFACT
      value: $(tasks.prefetch-dependencies.results.CACHI2_ARTIFACT)
    - name: IMAGE
      value: quay.io/myorg/compressed-llama3-8b:latest
    - name: COMPRESSOR_IMAGE
      value: quay.io/myorg/llm-compressor:latest
    - name: SCRIPT
      value: "scripts/compress_model.py"
    - name: HERMETIC
      value: "true"
    - name: PLATFORM
      value: "linux-g/amd64"  # GPU-enabled platform
    - name: IMAGE_APPEND_PLATFORM
      value: "true"  # Creates quay.io/myorg/compressed-llama3-8b:latest-linux-g-amd64
  runAfter:
    - prefetch-dependencies
  taskRef:
    name: llm-compressor-remote-oci-ta
    version: "0.1"
```

### 3. Multi-Platform Builds

Build compressed models for multiple platforms:

```yaml
- name: compress-model-gpu-x86
  params:
    - name: PLATFORM
      value: "linux-g/amd64"
    - name: IMAGE_APPEND_PLATFORM
      value: "true"
  taskRef:
    name: llm-compressor-remote-oci-ta

- name: compress-model-gpu-arm
  params:
    - name: PLATFORM
      value: "linux-g/arm64"
    - name: IMAGE_APPEND_PLATFORM
      value: "true"
  taskRef:
    name: llm-compressor-remote-oci-ta
```

Results in:
- `quay.io/myorg/model:latest-linux-g-amd64`
- `quay.io/myorg/model:latest-linux-g-arm64`

## Compression Script Requirements

Your compression script must:

1. **Read input** from `/var/workdir/source`
2. **Write output** to `$OUTPUT_DIR` (default: `/var/workdir/output`)
3. **Use GPU** if available (automatically provided on `linux-g*` platforms)

### Example GPU-Enabled Script

```python
#!/usr/bin/env python3
import os
import torch
from llmcompressor.transformers import oneshot

# Check GPU availability
device = "cuda" if torch.cuda.is_available() else "cpu"
print(f"Using device: {device}")

output_dir = os.environ.get("OUTPUT_DIR", "/var/workdir/output")

# Compress with GPU acceleration
oneshot(
    model="meta-llama/Meta-Llama-3-8B",
    dataset="open_platypus",
    recipe="gptq",
    output_dir=output_dir,
    device=device,  # GPU will be used on linux-g platforms
)

print(f"Model compressed and saved to {output_dir}")
```

## Remote Execution Flow

1. **Connection Setup** - Task connects to remote VM via SSH
2. **Rsync Source** - Syncs source code and dependencies to remote
3. **Remote Execution** - Runs compression script in podman container on remote
4. **Rsync Results** - Syncs OUTPUT_DIR back to local
5. **Push Artifacts** - Pushes compressed model to registry (locally)
6. **Generate SBOM** - Creates and uploads SBOM (locally)

## Localhost Fallback

If SSH_HOST is "localhost", the task executes compression locally instead of remotely. This is useful for:
- Testing without multi-platform-controller
- In-cluster GPU nodes
- Development environments

## Security Considerations

- Compression executes on remote VM with root privileges
- Network isolation maintained via HERMETIC=true
- SSH keys are ephemeral (per-TaskRun)
- Output files validated and restricted to OUTPUT_DIR
- GPU device access requires label=disable security option

## Related Tasks

- `llm-compressor-oci-ta` - Base task for in-cluster execution
- `buildah-remote-oci-ta` - Similar remote execution pattern
- `prefetch-dependencies-oci-ta` - Dependency prefetching
- `source-build-oci-ta` - Source container generation
