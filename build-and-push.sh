#!/bin/bash
# Build script for logstash-output-elasticsearch Docker image

set -e

# Configuration
IMAGE_NAME="${IMAGE_NAME:-logstash-custom-elasticsearch-output}"
IMAGE_TAG="${IMAGE_TAG:-8.4.0-custom}"
LOGSTASH_VERSION="${LOGSTASH_VERSION:-8.4.0}"
REGISTRY="${REGISTRY:-}" # Set to your registry, e.g., "docker.io/username" or "your-registry.azurecr.io"

# Full image name
if [ -n "$REGISTRY" ]; then
    FULL_IMAGE_NAME="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
else
    FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"
fi

echo "=========================================="
echo "Building Logstash Docker Image"
echo "=========================================="
echo "Base Logstash Version: ${LOGSTASH_VERSION}"
echo "Image Name: ${FULL_IMAGE_NAME}"
echo "=========================================="

# Build the Docker image
docker build \
    --build-arg LOGSTASH_VERSION="${LOGSTASH_VERSION}" \
    -t "${FULL_IMAGE_NAME}" \
    -f Dockerfile \
    .

echo ""
echo "=========================================="
echo "Build Complete!"
echo "=========================================="
echo "Image: ${FULL_IMAGE_NAME}"
echo ""

# Ask if user wants to push
if [ -n "$REGISTRY" ]; then
    read -p "Do you want to push the image to ${REGISTRY}? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Pushing image to registry..."
        docker push "${FULL_IMAGE_NAME}"
        echo "Push complete!"
    fi
fi

echo ""
echo "To use this image locally:"
echo "  docker run -it --rm ${FULL_IMAGE_NAME} --version"
echo ""
echo "To update your Kubernetes StatefulSet:"
echo "  kubectl set image statefulset/logstash-logstash logstash=${FULL_IMAGE_NAME} -n elastic-search"
echo ""
