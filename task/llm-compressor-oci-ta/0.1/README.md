# llm-compressor-oci-ta

Compresses large language models using llm-compressor from the vllm project and pushes the compressed model as an OCI artifact to a container registry. The task executes user-provided Python compression scripts in a hermetic environment with optional cachi2-prefetched dependencies.

## Overview

This task allows data scientists to compress LLM models as part of a Konflux build pipeline while maintaining:
- **Hermetic execution** - No network access during compression by default
- **Reproducibility** - Dependencies prefetched via hermeto/cachi2
- **Traceability** - Source containers and SBOMs automatically generated
- **Security** - Scripts run in isolated containers with controlled permissions

## Parameters

| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| SOURCE_ARTIFACT | Trusted artifact URI with compression script and source | - | Yes |
| IMAGE | OCI reference where compressed model will be pushed | - | Yes |
| COMPRESSOR_IMAGE | Container image with llm-compressor installed | - | Yes |
| SCRIPT | Python script that performs compression | - | Yes |
| CACHI2_ARTIFACT | Trusted artifact with prefetched dependencies | "" | No |
| HERMETIC | Execute compression without network access | "true" | No |
| OUTPUT_DIR | Directory where script writes output files | /var/workdir/output | No |
| SBOM_TYPE | SBOM format (spdx or cyclonedx) | spdx | No |
| STORAGE_DRIVER | Buildah storage driver | vfs | No |
| caTrustConfigMapName | ConfigMap name for CA bundle | trusted-ca | No |
| caTrustConfigMapKey | Key in ConfigMap for CA bundle | ca-bundle.crt | No |

## Results

| Result | Description |
|--------|-------------|
| IMAGE_DIGEST | Digest of the compressed model artifact |
| IMAGE_URL | Repository where artifact was pushed |
| IMAGE_REF | Full image reference with digest |
| SBOM_BLOB_URL | Reference to SBOM blob |
| COMPRESSOR_IMAGE_REFERENCE | Reference and digest of compressor image |

## Compression Script Requirements

Your Python compression script must:

1. **Read input** from `/var/workdir/source` (your source code repository)
2. **Write output** to the directory specified in `OUTPUT_DIR` parameter (default: `/var/workdir/output`)
3. **Use environment variables** set by hermeto for offline operation

### Environment Variables

When using hermetic builds with prefetched dependencies, hermeto automatically sets:

- `HF_HUB_OFFLINE=1` - Forces Hugging Face Hub to work offline
- `HF_DATASETS_OFFLINE=1` - Forces Hugging Face Datasets to work offline
- `HF_HOME` - Points to cached models/datasets location

These variables ensure llm-compressor uses prefetched models instead of attempting downloads.

### Example Compression Script

```python
#!/usr/bin/env python3
import os
from llmcompressor.modifiers.quantization import GPTQModifier
from llmcompressor.transformers import oneshot

# Input model should be prefetched via hermeto
model_name = "meta-llama/Meta-Llama-3-8B"

# Output directory from task parameter
output_dir = os.environ.get("OUTPUT_DIR", "/var/workdir/output")

# Configure compression
recipe = GPTQModifier(targets="Linear", scheme="W4A16", ignore=["lm_head"])

# Compress the model
oneshot(
    model=model_name,
    dataset="open_platypus",
    recipe=recipe,
    output_dir=output_dir,
    overwrite_output_dir=True,
)

print(f"Model compressed and saved to {output_dir}")
```

## Usage Example

### 1. Prefetch Dependencies

First, use `prefetch-dependencies-oci-ta` to cache the model and dependencies:

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
    version: "0.2"
```

Your `requirements.txt` should include:
```
llm-compressor
transformers
torch
huggingface-hub
```

### 2. Run Compression

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
      value: |
        #!/usr/bin/env python3
        import os
        from llmcompressor.transformers import oneshot

        output_dir = os.environ.get("OUTPUT_DIR", "/var/workdir/output")
        oneshot(
            model="meta-llama/Meta-Llama-3-8B",
            dataset="open_platypus",
            recipe="gptq",
            output_dir=output_dir,
        )
    - name: HERMETIC
      value: "true"
  runAfter:
    - prefetch-dependencies
  taskRef:
    name: llm-compressor-oci-ta
    version: "0.1"
```

### 3. Source Container Generation

The compressed model artifact is compatible with `source-build-oci-ta`:

```yaml
- name: build-source-container
  params:
    - name: BINARY_IMAGE
      value: $(tasks.compress-model.results.IMAGE_URL)
    - name: BINARY_IMAGE_DIGEST
      value: $(tasks.compress-model.results.IMAGE_DIGEST)
    - name: SOURCE_ARTIFACT
      value: $(tasks.prefetch-dependencies.results.SOURCE_ARTIFACT)
    - name: CACHI2_ARTIFACT
      value: $(tasks.prefetch-dependencies.results.CACHI2_ARTIFACT)
  runAfter:
    - compress-model
  taskRef:
    name: source-build-oci-ta
    version: "0.3"
```

## OCI Artifact Structure

The compressed model is pushed as an OCI artifact with:

- **artifactType**: `application/vnd.ai.model.llm.compressed`
- **Layers**: Each file from OUTPUT_DIR as a separate blob
- **Media Types**:
  - `.safetensors` files: `application/vnd.ai.model.safetensors`
  - `.json` files: `application/vnd.ai.model.config+json`
  - `.bin` files: `application/vnd.ai.model.weights`
  - Other files: `application/octet-stream`
- **Annotations**: `org.opencontainers.image.title` contains the file path

## Building the Compressor Image

Create a container image with llm-compressor and dependencies:

```dockerfile
FROM python:3.11-slim

RUN pip install --no-cache-dir \
    llm-compressor \
    transformers \
    torch \
    huggingface-hub \
    && pip cache purge

WORKDIR /workspace
```

## Security Considerations

- Scripts run as root inside an isolated buildah container
- Network access is disabled by default (HERMETIC=true)
- All dependencies should be prefetched via hermeto
- Output files are restricted to OUTPUT_DIR path
- CA certificates can be injected via ConfigMap

## Limitations

- Compression can be resource-intensive; adjust memory limits as needed
- Large models may require significant disk space
- Hermetic builds require all models/datasets to be prefetched

## Related Tasks

- `prefetch-dependencies-oci-ta` - Prefetch Python dependencies and models
- `source-build-oci-ta` - Generate source containers
- `buildah-oci-ta` - Similar hermetic build pattern for containers
- `run-script-oci-ta` - Generic script execution task
