#!/bin/bash
# Quick build script for dynamic ILM plugin

set -e

echo "=========================================="
echo "Building Logstash with Dynamic ILM Plugin"
echo "=========================================="
echo ""

# Configuration
IMAGE_NAME="logstash-dynamic-ilm"
IMAGE_TAG="8.4.0-custom"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

echo "Image: ${FULL_IMAGE}"
echo ""

# Build
echo "Building Docker image..."
docker build -t "${FULL_IMAGE}" .

echo ""
echo "=========================================="
echo "✅ Build Complete!"
echo "=========================================="
echo ""
echo "Image: ${FULL_IMAGE}"
echo ""
echo "Next steps:"
echo "  1. Test locally:"
echo "     docker-compose -f docker-compose.test.yml up"
echo ""
echo "  2. Tag for registry:"
echo "     docker tag ${FULL_IMAGE} yourregistry.azurecr.io/${FULL_IMAGE}"
echo ""
echo "  3. Push to registry:"
echo "     docker push yourregistry.azurecr.io/${FULL_IMAGE}"
echo ""
echo "  4. Deploy to Kubernetes:"
echo "     kubectl set image statefulset/logstash-logstash \\"
echo "       logstash=yourregistry.azurecr.io/${FULL_IMAGE} \\"
echo "       -n elastic-search"
echo ""
