#!/usr/bin/env python3
"""
Mock compression script for testing llm-compressor-oci-ta task.

This script simulates the output of llm-compressor without actually performing
any model compression. It completes in seconds instead of hours, making it
suitable for CI/CD testing.
"""
import os
import json
import time
import sys

def main():
    print("Starting mock model compression...")

    # Get output directory from environment or use default
    output_dir = os.environ.get("OUTPUT_DIR", "/var/workdir/output")

    print(f"Output directory: {output_dir}")

    # Create output directory if it doesn't exist
    os.makedirs(output_dir, exist_ok=True)

    # Create mock model files that llm-compressor would typically produce

    # 1. Model weights in safetensors format
    weights_file = os.path.join(output_dir, "model.safetensors")
    with open(weights_file, "w") as f:
        f.write("MOCK_COMPRESSED_MODEL_WEIGHTS_DATA_" * 100)
    print(f"Created mock weights file: {weights_file}")

    # 2. Model configuration
    config_file = os.path.join(output_dir, "config.json")
    config = {
        "model_type": "mamallama",
        "hidden_size": 4096,
        "num_hidden_layers": 32,
        "num_attention_heads": 32,
        "vocab_size": 32000,
        "compressed": True,
        "compression_method": "gptq",
        "quantization": {
            "bits": 4,
            "group_size": 128,
            "scheme": "W4A16"
        }
    }
    with open(config_file, "w") as f:
        json.dump(config, f, indent=2)
    print(f"Created mock config file: {config_file}")

    # 3. Tokenizer configuration
    tokenizer_config_file = os.path.join(output_dir, "tokenizer_config.json")
    tokenizer_config = {
        "model_max_length": 2048,
        "tokenizer_class": "LlamaTokenizer",
        "bos_token": "<s>",
        "eos_token": "</s>",
        "unk_token": "<unk>"
    }
    with open(tokenizer_config_file, "w") as f:
        json.dump(tokenizer_config, f, indent=2)
    print(f"Created mock tokenizer config: {tokenizer_config_file}")

    # 4. Tokenizer model
    tokenizer_file = os.path.join(output_dir, "tokenizer.json")
    tokenizer_data = {
        "version": "1.0",
        "vocab_size": 32000,
        "model": "mock_tokenizer"
    }
    with open(tokenizer_file, "w") as f:
        json.dump(tokenizer_data, f, indent=2)
    print(f"Created mock tokenizer file: {tokenizer_file}")

    # 5. Additional metadata file
    metadata_file = os.path.join(output_dir, "compression_metadata.json")
    metadata = {
        "original_model": "meta-llama/Meta-Llama-3-8B",
        "compression_date": "2025-10-16",
        "compression_tool": "llm-compressor",
        "compression_tool_version": "0.1.0-mock",
        "dataset": "open_platypus",
        "hermetic": os.environ.get("HERMETIC", "false") == "true"
    }
    with open(metadata_file, "w") as f:
        json.dump(metadata, f, indent=2)
    print(f"Created mock metadata file: {metadata_file}")

    # 6. Environment variables file (for hermetic verification)
    env_file = os.path.join(output_dir, "environment.json")
    env_info = {
        "HF_HUB_OFFLINE": os.environ.get("HF_HUB_OFFLINE", "NOT_SET"),
        "HF_DATASETS_OFFLINE": os.environ.get("HF_DATASETS_OFFLINE", "NOT_SET"),
        "HF_HOME": os.environ.get("HF_HOME", "NOT_SET"),
        "TRANSFORMERS_OFFLINE": os.environ.get("TRANSFORMERS_OFFLINE", "NOT_SET"),
        "PIP_INDEX_URL": os.environ.get("PIP_INDEX_URL", "NOT_SET")
    }
    with open(env_file, "w") as f:
        json.dump(env_info, f, indent=2)
    print(f"Created environment file: {env_file}")

    # List all created files
    print("\nMock compression complete! Created files:")
    for filename in os.listdir(output_dir):
        filepath = os.path.join(output_dir, filename)
        size = os.path.getsize(filepath)
        print(f"  - {filename} ({size} bytes)")

    # Print environment information
    print("\nEnvironment variables:")
    for key, value in env_info.items():
        print(f"  {key}={value}")

    # Verify hermetic environment if expected
    if os.environ.get("HERMETIC", "false") == "true":
        print("\nHermetic mode verification:")
        if env_info["HF_HUB_OFFLINE"] != "1":
            print("  WARNING: HF_HUB_OFFLINE is not set to 1")
        if env_info["HF_DATASETS_OFFLINE"] != "1":
            print("  WARNING: HF_DATASETS_OFFLINE is not set to 1")
        if env_info["HF_HOME"] == "NOT_SET":
            print("  WARNING: HF_HOME is not set")

    print("\nMock compression script completed successfully!")
    return 0

if __name__ == "__main__":
    sys.exit(main())
