# Setup Instructions

## Overview

This guide provides step-by-step instructions for setting up and deploying Logstash with Dynamic ILM capabilities. Follow these instructions to build, test, and deploy the modified plugin to your environment.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Local Development Setup](#local-development-setup)
3. [Building the Plugin](#building-the-plugin)
4. [Testing Locally](#testing-locally)
5. [Docker Deployment](#docker-deployment)
6. [Kubernetes Deployment](#kubernetes-deployment)
7. [Elasticsearch Configuration](#elasticsearch-configuration)
8. [Verification](#verification)
9. [Upgrading Existing Deployments](#upgrading-existing-deployments)
10. [Rollback Procedures](#rollback-procedures)

---

## Prerequisites

### Required Software

| Software    | Version | Purpose                            |
| ----------- | ------- | ---------------------------------- |
| Docker      | 20.10+  | Build and run containers           |
| Kubernetes  | 1.20+   | Container orchestration (optional) |
| kubectl     | 1.20+   | Kubernetes CLI (optional)          |
| Git         | 2.x     | Clone repository                   |
| Text editor | Any     | Edit configuration files           |

### Required Access

- **Docker Registry Access:** Push images to your container registry
- **Elasticsearch Cluster:** Version 7.x or higher
- **Elasticsearch Credentials:** User with appropriate permissions (see below)
- **Kubernetes Cluster:** If deploying to Kubernetes

### Elasticsearch Permissions

The Logstash user must have the following privileges:

```json
{
  "cluster": ["manage_ilm", "manage_index_templates", "monitor"],
  "indices": [
    {
      "names": ["*"],
      "privileges": ["create_index", "write", "manage", "manage_ilm"]
    }
  ]
}
```

**To create this role in Elasticsearch:**

```bash
# Create role
POST /_security/role/logstash_dynamic_ilm
{
  "cluster": ["manage_ilm", "manage_index_templates", "monitor"],
  "indices": [
    {
      "names": ["*"],
      "privileges": ["create_index", "write", "manage", "manage_ilm"]
    }
  ]
}

# Assign role to user
POST /_security/user/logstash
{
  "password": "your-secure-password",
  "roles": ["logstash_dynamic_ilm"],
  "full_name": "Logstash Service Account"
}
```

---

## Local Development Setup

### 1. Clone Repository

```bash
git clone <your-repository-url>
cd logstash-output-elasticsearch
```

### 2. Verify File Structure

Ensure all modified files are present:

```
logstash-output-elasticsearch/
├── lib/logstash/outputs/
│   ├── elasticsearch.rb (modified)
│   └── elasticsearch/
│       ├── dynamic_template_manager.rb (NEW)
│       ├── ilm.rb (modified)
│       └── template_manager.rb (modified)
├── Dockerfile
├── .dockerignore
├── docker-compose.test.yml
├── test-pipeline.conf
├── build-and-push.sh
├── build-and-push.bat
└── examples/
    └── complete_dynamic_ilm.conf
```

### 3. Review Code Changes

**Key files to understand:**

- **`dynamic_template_manager.rb`** - Core logic for resource creation
- **`elasticsearch.rb`** - Configuration options and integration
- **`ilm.rb`** - Dynamic alias detection
- **`template_manager.rb`** - Template creation skip logic

---

## Building the Plugin

### Option 1: Docker Build (Recommended)

**For Linux/macOS:**

```bash
# Make script executable
chmod +x build-and-push.sh

# Build Docker image
./build-and-push.sh
```

**For Windows:**

```cmd
# Run batch file
build-and-push.bat
```

**Build script details:**

The script performs the following steps:

1. Converts Windows line endings (CRLF) to Unix (LF)
2. Builds the plugin gem from modified source
3. Creates Docker image with Logstash + modified plugin
4. Tags image as `your-registry/logstash-dynamic-ilm:latest`

**Customize registry in script:**

Edit `build-and-push.sh` or `build-and-push.bat`:

```bash
# Change this to your registry
REGISTRY="myregistry.azurecr.io"
IMAGE_NAME="logstash-dynamic-ilm"
VERSION="1.0.0"

docker build -t ${REGISTRY}/${IMAGE_NAME}:${VERSION} .
docker tag ${REGISTRY}/${IMAGE_NAME}:${VERSION} ${REGISTRY}/${IMAGE_NAME}:latest
```

### Option 2: Manual Build

If you prefer manual steps:

```bash
# 1. Convert line endings (Linux/macOS)
find lib -type f -name "*.rb" -exec dos2unix {} \;

# 2. Build gem
gem build logstash-output-elasticsearch.gemspec

# 3. Build Docker image
docker build -t logstash-dynamic-ilm:latest .
```

### Verify Build

```bash
# List Docker images
docker images | grep logstash-dynamic-ilm

# Expected output:
# logstash-dynamic-ilm   latest   abc123def456   2 minutes ago   850MB
```

---

## Testing Locally

### 1. Start Elasticsearch with Docker Compose

```bash
# Start Elasticsearch and Kibana
docker-compose -f docker-compose.test.yml up -d elasticsearch kibana

# Wait for Elasticsearch to be ready (may take 1-2 minutes)
docker-compose -f docker-compose.test.yml logs -f elasticsearch
```

**Wait for this message:**

```
"message": "started"
```

### 2. Configure Test Pipeline

Edit `test-pipeline.conf` with your settings:

```ruby
input {
  generator {
    message => '{"container_name": "test-app", "message": "Test log message"}'
    codec => json
    count => 10
  }
}

output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    user => "elastic"
    password => "changeme"
    ssl_enabled => false

    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"

    ilm_rollover_max_age => "1d"
    ilm_delete_min_age => "7d"
  }

  stdout { codec => rubydebug }
}
```

### 3. Run Logstash Container

```bash
# Start Logstash with test pipeline
docker-compose -f docker-compose.test.yml up logstash

# Watch logs for resource creation
docker-compose -f docker-compose.test.yml logs -f logstash
```

**Expected log output:**

```
[INFO] Creating dynamic ILM policy: test-app-ilm-policy
[INFO] Creating dynamic index template: logstash-test-app
[INFO] Creating rollover index for alias: test-app
[INFO] Successfully indexed 10 events
```

### 4. Verify in Elasticsearch

**Check ILM policy:**

```bash
curl -u elastic:changeme http://localhost:9200/_ilm/policy/test-app-ilm-policy
```

**Check index template:**

```bash
curl -u elastic:changeme http://localhost:9200/_index_template/logstash-test-app
```

**Check rollover index:**

```bash
curl -u elastic:changeme http://localhost:9200/test-app
```

**Check indexed documents:**

```bash
curl -u elastic:changeme http://localhost:9200/test-app-*/_search?pretty
```

### 5. Test with Multiple Containers

Modify `test-pipeline.conf` to generate events from multiple containers:

```ruby
input {
  generator {
    message => '{"container_name": "nginx", "message": "nginx log"}'
    codec => json
    count => 5
  }
  generator {
    message => '{"container_name": "app", "message": "app log"}'
    codec => json
    count => 5
  }
  generator {
    message => '{"container_name": "redis", "message": "redis log"}'
    codec => json
    count => 5
  }
}
```

**Verify separate resources created:**

```bash
# Should see 3 policies
curl -u elastic:changeme http://localhost:9200/_ilm/policy | jq 'keys'
# ["nginx-ilm-policy", "app-ilm-policy", "redis-ilm-policy"]

# Should see 3 templates
curl -u elastic:changeme http://localhost:9200/_index_template | jq '.index_templates[].name'
# "logstash-nginx"
# "logstash-app"
# "logstash-redis"

# Should see 3 indices
curl -u elastic:changeme http://localhost:9200/_cat/indices/*-000001
```

### 6. Clean Up Test Environment

```bash
# Stop all containers
docker-compose -f docker-compose.test.yml down -v

# Remove test data
docker volume prune -f
```

---

## Docker Deployment

### 1. Push Image to Registry

**For Docker Hub:**

```bash
docker login
docker tag logstash-dynamic-ilm:latest yourusername/logstash-dynamic-ilm:1.0.0
docker push yourusername/logstash-dynamic-ilm:1.0.0
```

**For Azure Container Registry:**

```bash
# Login to ACR
az acr login --name myregistry

# Tag and push
docker tag logstash-dynamic-ilm:latest myregistry.azurecr.io/logstash-dynamic-ilm:1.0.0
docker push myregistry.azurecr.io/logstash-dynamic-ilm:1.0.0
```

**For AWS ECR:**

```bash
# Login to ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 123456789.dkr.ecr.us-east-1.amazonaws.com

# Tag and push
docker tag logstash-dynamic-ilm:latest 123456789.dkr.ecr.us-east-1.amazonaws.com/logstash-dynamic-ilm:1.0.0
docker push 123456789.dkr.ecr.us-east-1.amazonaws.com/logstash-dynamic-ilm:1.0.0
```

### 2. Create Configuration File

**Create `logstash.conf` for your environment:**

```ruby
input {
  beats {
    port => 5044
  }
}

filter {
  # Extract container name from metadata
  if [kubernetes][container][name] {
    mutate {
      add_field => { "container_name" => "%{[kubernetes][container][name]}" }
    }
  }

  # Sanitize container name for Elasticsearch
  mutate {
    lowercase => ["container_name"]
    gsub => ["container_name", "[^a-z0-9-]", "-"]
  }
}

output {
  elasticsearch {
    hosts => ["${ELASTICSEARCH_HOSTS}"]
    user => "${ELASTICSEARCH_USER}"
    password => "${ELASTICSEARCH_PASSWORD}"
    ssl_enabled => "${ELASTICSEARCH_SSL:true}"

    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"

    ilm_rollover_max_age => "${ILM_ROLLOVER_AGE:1d}"
    ilm_rollover_max_size => "${ILM_ROLLOVER_SIZE:50gb}"
    ilm_hot_priority => "${ILM_HOT_PRIORITY:50}"
    ilm_delete_min_age => "${ILM_DELETE_AGE:7d}"
    ilm_delete_enabled => "${ILM_DELETE_ENABLED:true}"
  }
}
```

### 3. Run with Docker

```bash
# Run Logstash container
docker run -d \
  --name logstash \
  -p 5044:5044 \
  -v $(pwd)/logstash.conf:/usr/share/logstash/pipeline/logstash.conf \
  -e ELASTICSEARCH_HOSTS="http://elasticsearch:9200" \
  -e ELASTICSEARCH_USER="elastic" \
  -e ELASTICSEARCH_PASSWORD="your-password" \
  -e ILM_ROLLOVER_AGE="1d" \
  -e ILM_DELETE_AGE="7d" \
  --network elastic \
  myregistry.azurecr.io/logstash-dynamic-ilm:1.0.0
```

### 4. Verify Deployment

```bash
# Check logs
docker logs -f logstash

# Verify Logstash started
docker ps | grep logstash

# Test connectivity
docker exec logstash curl -u elastic:password http://elasticsearch:9200/_cluster/health
```

---

## Kubernetes Deployment

### 1. Create Namespace

```bash
kubectl create namespace logging
```

### 2. Create Secrets

**Elasticsearch credentials:**

```bash
kubectl create secret generic elasticsearch-credentials \
  --from-literal=username=elastic \
  --from-literal=password=your-secure-password \
  -n logging
```

### 3. Create ConfigMap

**Save as `logstash-configmap.yaml`:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: logstash-config
  namespace: logging
data:
  logstash.conf: |
    input {
      beats {
        port => 5044
      }
    }

    filter {
      if [kubernetes][container][name] {
        mutate {
          add_field => { "container_name" => "%{[kubernetes][container][name]}" }
        }
      }
      
      mutate {
        lowercase => ["container_name"]
        gsub => ["container_name", "[^a-z0-9-]", "-"]
      }
    }

    output {
      elasticsearch {
        hosts => ["https://elasticsearch-es-http:9200"]
        user => "${ELASTICSEARCH_USER}"
        password => "${ELASTICSEARCH_PASSWORD}"
        ssl_enabled => true
        cacert => "/etc/elasticsearch/certs/ca.crt"
        
        ilm_enabled => true
        ilm_rollover_alias => "%{[container_name]}"
        
        ilm_rollover_max_age => "1d"
        ilm_rollover_max_size => "50gb"
        ilm_hot_priority => 50
        ilm_delete_min_age => "7d"
        ilm_delete_enabled => true
      }
    }
```

**Apply ConfigMap:**

```bash
kubectl apply -f logstash-configmap.yaml
```

### 4. Create Deployment

**Save as `logstash-deployment.yaml`:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: logstash
  namespace: logging
spec:
  replicas: 2
  selector:
    matchLabels:
      app: logstash
  template:
    metadata:
      labels:
        app: logstash
    spec:
      containers:
        - name: logstash
          image: myregistry.azurecr.io/logstash-dynamic-ilm:1.0.0
          ports:
            - containerPort: 5044
              name: beats
          env:
            - name: ELASTICSEARCH_USER
              valueFrom:
                secretKeyRef:
                  name: elasticsearch-credentials
                  key: username
            - name: ELASTICSEARCH_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: elasticsearch-credentials
                  key: password
            - name: LS_JAVA_OPTS
              value: "-Xmx2g -Xms2g"
          volumeMounts:
            - name: config
              mountPath: /usr/share/logstash/pipeline
            - name: elasticsearch-certs
              mountPath: /etc/elasticsearch/certs
              readOnly: true
          resources:
            requests:
              memory: "2Gi"
              cpu: "500m"
            limits:
              memory: "4Gi"
              cpu: "2000m"
          livenessProbe:
            httpGet:
              path: /
              port: 9600
            initialDelaySeconds: 60
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /
              port: 9600
            initialDelaySeconds: 30
            periodSeconds: 5
      volumes:
        - name: config
          configMap:
            name: logstash-config
        - name: elasticsearch-certs
          secret:
            secretName: elasticsearch-es-http-certs-public
```

**Apply Deployment:**

```bash
kubectl apply -f logstash-deployment.yaml
```

### 5. Create Service

**Save as `logstash-service.yaml`:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: logstash
  namespace: logging
spec:
  type: ClusterIP
  ports:
    - port: 5044
      targetPort: 5044
      name: beats
    - port: 9600
      targetPort: 9600
      name: http
  selector:
    app: logstash
```

**Apply Service:**

```bash
kubectl apply -f logstash-service.yaml
```

### 6. Verify Kubernetes Deployment

```bash
# Check pods
kubectl get pods -n logging

# Check logs
kubectl logs -f deployment/logstash -n logging

# Check service
kubectl get svc -n logging

# Port-forward for testing
kubectl port-forward svc/logstash 5044:5044 -n logging
```

### 7. Configure Log Shippers

**Filebeat configuration example:**

```yaml
filebeat.inputs:
  - type: container
    paths:
      - /var/log/containers/*.log

output.logstash:
  hosts: ["logstash.logging.svc.cluster.local:5044"]
```

---

## Elasticsearch Configuration

### 1. Enable ILM

Verify ILM is enabled (default in Elasticsearch 7.x+):

```bash
GET /_cluster/settings

# Should show:
{
  "persistent": {
    "xpack.ilm.enabled": "true"
  }
}
```

If not enabled:

```bash
PUT /_cluster/settings
{
  "persistent": {
    "xpack.ilm.enabled": true
  }
}
```

### 2. Configure Index Lifecycle Policies

The plugin creates policies automatically, but you can pre-create policies for specific containers:

```bash
PUT _ilm/policy/high-priority-app-ilm-policy
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {
            "max_age": "6h",
            "max_size": "25gb"
          },
          "set_priority": {
            "priority": 100
          }
        }
      },
      "delete": {
        "min_age": "30d",
        "actions": {
          "delete": {}
        }
      }
    }
  }
}
```

### 3. Set Up Monitoring

**Enable ILM monitoring:**

```bash
GET _ilm/policy/*/_explain
```

**Set up alerting (example with Watcher):**

```bash
PUT _watcher/watch/ilm-failures
{
  "trigger": {
    "schedule": {
      "interval": "5m"
    }
  },
  "input": {
    "search": {
      "request": {
        "indices": ["*"],
        "body": {
          "query": {
            "match": {
              "ilm.phase": "ERROR"
            }
          }
        }
      }
    }
  },
  "actions": {
    "log_error": {
      "logging": {
        "level": "error",
        "text": "ILM policy execution failed"
      }
    }
  }
}
```

---

## Verification

### 1. End-to-End Test

**Send test log:**

```bash
# If using Filebeat
echo '{"container_name": "verification-test", "message": "Test message"}' | \
  filebeat -e -c filebeat.yml
```

**Or use Logstash generator:**

```ruby
input {
  generator {
    message => '{"container_name": "verification-test", "message": "Test"}'
    codec => json
    count => 1
  }
}
```

### 2. Verify Resource Creation

**Check policy:**

```bash
GET _ilm/policy/verification-test-ilm-policy

# Expected response:
{
  "verification-test-ilm-policy": {
    "policy": {
      "phases": {
        "hot": { ... },
        "delete": { ... }
      }
    }
  }
}
```

**Check template:**

```bash
GET _index_template/logstash-verification-test
```

**Check index:**

```bash
GET verification-test-*

# Should show index like: verification-test-2025.11.15-000001
```

**Check document:**

```bash
GET verification-test-*/_search
{
  "query": {
    "match": {
      "container_name": "verification-test"
    }
  }
}
```

### 3. Verify ILM Execution

**Check ILM status:**

```bash
GET verification-test-*/_ilm/explain

# Should show:
{
  "indices": {
    "verification-test-2025.11.15-000001": {
      "phase": "hot",
      "action": "rollover",
      "managed": true
    }
  }
}
```

### 4. Test Customization

**Modify policy in Kibana:**

```bash
PUT _ilm/policy/verification-test-ilm-policy
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {
            "max_age": "12h"  # Changed from 1d
          },
          "set_priority": {
            "priority": 75
          }
        }
      },
      "delete": {
        "min_age": "3d"  # Changed from 7d
        "actions": {
          "delete": {}
        }
      }
    }
  }
}
```

**Send another test event:**

```bash
# Generate new event
echo '{"container_name": "verification-test", "message": "Test 2"}' | \
  filebeat -e -c filebeat.yml

# Verify policy wasn't overwritten
GET _ilm/policy/verification-test-ilm-policy

# Should still show max_age: 12h (your custom value)
```

---

## Upgrading Existing Deployments

### 1. Backup Current Configuration

```bash
# Save current Logstash config
kubectl get configmap logstash-config -n logging -o yaml > logstash-config-backup.yaml

# Save current deployment
kubectl get deployment logstash -n logging -o yaml > logstash-deployment-backup.yaml
```

### 2. Update Image

**Edit deployment:**

```bash
kubectl set image deployment/logstash \
  logstash=myregistry.azurecr.io/logstash-dynamic-ilm:1.0.0 \
  -n logging
```

**Or patch deployment:**

```bash
kubectl patch deployment logstash -n logging -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"logstash","image":"myregistry.azurecr.io/logstash-dynamic-ilm:1.0.0"}]}}}}'
```

### 3. Update Configuration

**Add dynamic ILM settings to ConfigMap:**

```bash
kubectl edit configmap logstash-config -n logging
```

**Add these lines to elasticsearch output:**

```ruby
ilm_enabled => true
ilm_rollover_alias => "%{[container_name]}"
ilm_rollover_max_age => "1d"
ilm_delete_min_age => "7d"
```

### 4. Rolling Update

```bash
# Restart pods to pick up new config
kubectl rollout restart deployment/logstash -n logging

# Monitor rollout
kubectl rollout status deployment/logstash -n logging

# Watch logs
kubectl logs -f deployment/logstash -n logging
```

### 5. Verify Upgrade

```bash
# Check pod image
kubectl describe pod -l app=logstash -n logging | grep Image

# Check logs for dynamic ILM messages
kubectl logs -l app=logstash -n logging | grep "Creating dynamic"

# Test with new container
kubectl run test-pod --image=busybox --restart=Never -- sh -c "echo test > /dev/stdout"
```

---

## Rollback Procedures

### If Upgrade Fails

**Option 1: Rollback Deployment**

```bash
# Rollback to previous version
kubectl rollout undo deployment/logstash -n logging

# Verify rollback
kubectl rollout status deployment/logstash -n logging
```

**Option 2: Restore from Backup**

```bash
# Restore old deployment
kubectl apply -f logstash-deployment-backup.yaml

# Restore old config
kubectl apply -f logstash-config-backup.yaml

# Restart pods
kubectl rollout restart deployment/logstash -n logging
```

### If Resource Creation Issues

**Disable dynamic ILM temporarily:**

```bash
# Edit ConfigMap
kubectl edit configmap logstash-config -n logging

# Change:
ilm_rollover_alias => "%{[container_name]}"
# To:
ilm_rollover_alias => "logstash"

# Restart
kubectl rollout restart deployment/logstash -n logging
```

### If Elasticsearch Issues

**Check Elasticsearch health:**

```bash
GET _cluster/health

# If unhealthy, check nodes
GET _cat/nodes?v
```

**Check ILM status:**

```bash
GET _ilm/status

# If stopped, start ILM
POST _ilm/start
```

---

## Troubleshooting Common Issues

### Issue: Pods not starting

**Check:**

```bash
kubectl describe pod -l app=logstash -n logging
kubectl logs -l app=logstash -n logging --previous
```

**Common causes:**

- Image pull errors (check registry credentials)
- ConfigMap syntax errors
- Resource limits too low

### Issue: Events not indexed

**Check:**

```bash
# Logstash logs
kubectl logs -l app=logstash -n logging | grep ERROR

# Elasticsearch logs
kubectl logs -l app=elasticsearch -n elastic-system | grep ERROR
```

**Common causes:**

- Network connectivity issues
- Authentication failures
- Missing permissions

### Issue: Resources not created

**Check Logstash logs:**

```bash
kubectl logs -l app=logstash -n logging | grep "dynamic ILM"
```

**Verify permissions:**

```bash
# Test with Elasticsearch user
curl -u elastic:password http://elasticsearch:9200/_security/user/_privileges
```

---

## Next Steps

After successful deployment:

1. **Monitor Performance**

   - Set up metrics collection
   - Monitor index sizes
   - Track rollover frequency

2. **Configure Alerts**

   - ILM execution failures
   - Index size thresholds
   - Logstash errors

3. **Optimize Settings**

   - Adjust rollover criteria based on actual usage
   - Customize retention periods per container
   - Tune Logstash JVM settings

4. **Document Customizations**

   - Keep record of manually customized policies
   - Document container-specific requirements
   - Maintain runbook for operations team

5. **Review User Guide**
   - See `03_USER_GUIDE.md` for detailed usage instructions
   - Review best practices and common patterns
   - Understand customization workflows

---

## Summary

You now have a fully functional Logstash deployment with Dynamic ILM capabilities:

✅ **Plugin built and deployed**
✅ **Elasticsearch configured with proper permissions**
✅ **Kubernetes deployment running**
✅ **Resources automatically created per container**
✅ **Verification tests passed**

For day-to-day usage and advanced configurations, refer to **03_USER_GUIDE.md**.

For technical details about the implementation, see **02_CODE_CHANGES.md** and **COMPLETE_DYNAMIC_ILM_SOLUTION.md**.
