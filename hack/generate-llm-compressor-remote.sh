#!/bin/bash
set -euo pipefail

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

cd "${SCRIPTDIR}/../task-generator/llm-compressor-remote"
GOTOOLCHAIN=auto GOSUMDB=sum.golang.org go build -o /tmp/llm-compressor-remote-generator main.go

for version in 0.1; do
    /tmp/llm-compressor-remote-generator \
        --input-task="${SCRIPTDIR}/../task/llm-compressor-oci-ta/${version}/llm-compressor-oci-ta.yaml" \
        --output-task="${SCRIPTDIR}/../task/llm-compressor-remote-oci-ta/${version}/llm-compressor-remote-oci-ta.yaml" \
        --task-version="$version"
done
