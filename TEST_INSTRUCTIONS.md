# Testing Your Modified Logstash Elasticsearch Output Plugin

This guide provides instructions for building and testing your modified `logstash-output-elasticsearch` plugin.

## Prerequisites

- Docker installed and running
- For Kubernetes deployment: `kubectl` configured with access to your cluster
- For registry push: Access to your container registry (ACR, Docker Hub, etc.)

## Option 1: Quick Local Test with Docker Compose

This is the fastest way to test your changes locally.

### Steps:

1. **Build and test locally:**

   ```bash
   docker-compose -f docker-compose.test.yml up --build
   ```

2. **Verify the output:**

   - Logstash should start and process the test events
   - Check for any errors in the logs
   - Verify events are sent to Elasticsearch

3. **Check Elasticsearch:**

   ```bash
   curl http://localhost:9200/_cat/indices?v
   curl http://localhost:9200/test-logstash-output-*/_search?pretty
   ```

4. **Clean up:**
   ```bash
   docker-compose -f docker-compose.test.yml down -v
   ```

## Option 2: Build Docker Image for Kubernetes

### On Windows (PowerShell or CMD):

```batch
# Build locally without pushing
build-and-push.bat

# Or set environment variables to customize
set IMAGE_NAME=logstash-custom-elasticsearch-output
set IMAGE_TAG=8.4.0-custom
set REGISTRY=your-registry.azurecr.io
build-and-push.bat
```

### On Windows (Bash/WSL):

```bash
# Build locally without pushing
./build-and-push.sh

# Or set environment variables to customize
export IMAGE_NAME=logstash-custom-elasticsearch-output
export IMAGE_TAG=8.4.0-custom
export REGISTRY=your-registry.azurecr.io
./build-and-push.sh
```

## Option 3: Manual Docker Build

```bash
# Build the image
docker build -t logstash-custom-elasticsearch-output:8.4.0-custom .

# Test the image
docker run -it --rm logstash-custom-elasticsearch-output:8.4.0-custom --version

# Verify plugin is installed
docker run -it --rm logstash-custom-elasticsearch-output:8.4.0-custom \
  bin/logstash-plugin list | grep elasticsearch
```

## Push to Container Registry

### Azure Container Registry (ACR):

```bash
# Login to ACR
az acr login --name <your-registry-name>

# Tag the image
docker tag logstash-custom-elasticsearch-output:8.4.0-custom \
  <your-registry-name>.azurecr.io/logstash-custom-elasticsearch-output:8.4.0-custom

# Push the image
docker push <your-registry-name>.azurecr.io/logstash-custom-elasticsearch-output:8.4.0-custom
```

### Docker Hub:

```bash
# Login to Docker Hub
docker login

# Tag the image
docker tag logstash-custom-elasticsearch-output:8.4.0-custom \
  <your-username>/logstash-custom-elasticsearch-output:8.4.0-custom

# Push the image
docker push <your-username>/logstash-custom-elasticsearch-output:8.4.0-custom
```

## Deploy to Kubernetes

### Update your StatefulSet:

```bash
# Update the image
kubectl set image statefulset/logstash-logstash \
  logstash=<your-registry>.azurecr.io/logstash-custom-elasticsearch-output:8.4.0-custom \
  -n elastic-search

# Watch the rollout
kubectl rollout status statefulset/logstash-logstash -n elastic-search

# Check logs
kubectl logs -f statefulset/logstash-logstash -n elastic-search
```

### Or update the YAML directly:

Edit your StatefulSet YAML and change:

```yaml
spec:
  template:
    spec:
      containers:
        - name: logstash
          image: <your-registry>.azurecr.io/logstash-custom-elasticsearch-output:8.4.0-custom
```

Then apply:

```bash
kubectl apply -f your-statefulset.yaml
```

## Verify the Changes

### In Kubernetes:

```bash
# Check pod status
kubectl get pods -n elastic-search -l app=logstash-logstash

# View logs from specific pod
kubectl logs logstash-logstash-0 -n elastic-search

# Exec into pod to verify plugin
kubectl exec -it logstash-logstash-0 -n elastic-search -- \
  /usr/share/logstash/bin/logstash-plugin list | grep elasticsearch
```

### Check Plugin Version:

```bash
kubectl exec -it logstash-logstash-0 -n elastic-search -- \
  /usr/share/logstash/bin/logstash-plugin list --verbose | grep logstash-output-elasticsearch
```

## Troubleshooting

### Build Issues:

1. **Bundle install fails:**

   - Check your Gemfile and gemspec dependencies
   - Ensure all required gems are accessible

2. **Gem build fails:**

   - Verify your gemspec file is valid
   - Check that all required files are present

3. **Plugin install fails:**
   - Check if there are dependency conflicts
   - Verify the gem was built successfully

### Runtime Issues:

1. **Check Logstash logs:**

   ```bash
   kubectl logs -f logstash-logstash-0 -n elastic-search
   ```

2. **Check plugin configuration:**

   ```bash
   kubectl get configmap logstash-logstash-pipeline -n elastic-search -o yaml
   ```

3. **Test Elasticsearch connectivity:**
   ```bash
   kubectl exec -it logstash-logstash-0 -n elastic-search -- \
     curl -X GET "http://<elasticsearch-service>:9200/_cluster/health?pretty"
   ```

## Rollback

If you need to rollback to the previous version:

```bash
# Rollback to previous revision
kubectl rollout undo statefulset/logstash-logstash -n elastic-search

# Or set back to original image
kubectl set image statefulset/logstash-logstash \
  logstash=opensearchproject/logstash-oss-with-opensearch-output-plugin:8.4.0 \
  -n elastic-search
```

## Additional Testing

For more comprehensive testing, you can use the existing integration tests:

```bash
# Run integration tests (requires Docker)
cd .ci
./docker-run.sh
```

Set environment variables for different test scenarios:

```bash
export INTEGRATION=true
export SECURE_INTEGRATION=true
./docker-run.sh
```
