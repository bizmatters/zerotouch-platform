#!/bin/bash
set -euo pipefail

IMAGE_TAR="/var/lib/zerotouch/platform-images.tar"
DONE_FILE="/var/lib/zerotouch/.imported"

if [ -f "$DONE_FILE" ]; then
    echo "Images already imported."
    exit 0
fi

if [ -f "$IMAGE_TAR" ]; then
    echo "Importing pre-cached platform images from $IMAGE_TAR..."
    # Import into the k8s.io namespace where Kind expects images
    ctr -n k8s.io images import "$IMAGE_TAR"
    echo "Import complete."
    touch "$DONE_FILE"
    # Optional: Delete tar to save space
    # rm "$IMAGE_TAR"
else
    echo "No image archive found at $IMAGE_TAR"
fi
