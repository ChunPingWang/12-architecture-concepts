# 12 Architecture Concepts PoC on Kind (Kubernetes in Docker)

## Overview

This project provides **12 hands-on Proof of Concepts (PoCs)** demonstrating essential distributed system architecture patterns. Each PoC is based on **Kind (Kubernetes in Docker)**, making it easy to run locally on your machine. These concepts are inspired by ByteByteGo's architectural fundamentals.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Quick Start](#quick-start)
3. [Architecture Concepts Overview](#architecture-concepts-overview)
4. [PoC Details](#poc-details)
   - [PoC 0: Cluster Setup](#poc-0-cluster-setup)
   - [PoC 1: Load Balancing](#poc-1-load-balancing)
   - [PoC 2: Caching](#poc-2-caching)
   - [PoC 3: CDN (Content Delivery Network)](#poc-3-cdn-content-delivery-network)
   - [PoC 4: Message Queue](#poc-4-message-queue)
   - [PoC 5: Publish-Subscribe](#poc-5-publish-subscribe)
   - [PoC 6: API Gateway](#poc-6-api-gateway)
   - [PoC 7: Circuit Breaker](#poc-7-circuit-breaker)
   - [PoC 8: Service Discovery](#poc-8-service-discovery)
   - [PoC 9: Sharding](#poc-9-sharding)
   - [PoC 10: Rate Limiting](#poc-10-rate-limiting)
   - [PoC 11: Consistent Hashing](#poc-11-consistent-hashing)
   - [PoC 12: Auto Scaling](#poc-12-auto-scaling)
5. [Port Reference](#port-reference)
6. [Cleanup](#cleanup)
7. [Troubleshooting](#troubleshooting)

---

## Prerequisites

| Tool | Version | Purpose | Installation |
|------|---------|---------|--------------|
| Docker | 24+ | Container runtime | [Install Docker](https://docs.docker.com/get-docker/) |
| Kind | 0.20+ | Local Kubernetes cluster | `brew install kind` or [Install Kind](https://kind.sigs.k8s.io/docs/user/quick-start/) |
| kubectl | 1.28+ | Kubernetes CLI | `brew install kubectl` or [Install kubectl](https://kubernetes.io/docs/tasks/tools/) |
| Helm | 3.12+ | Package manager for K8s | `brew install helm` or [Install Helm](https://helm.sh/docs/intro/install/) |
| curl/httpie | any | API testing | Pre-installed on most systems |
| jq | any | JSON processing | `brew install jq` |

### Verify Installation

```bash
docker --version
kind --version
kubectl version --client
helm version
```

---

## Quick Start

```bash
# 1. Create Kind cluster with all infrastructure
./scripts/00-setup-cluster.sh

# 2. Deploy all PoCs at once (optional)
./scripts/deploy-all.sh

# 3. Or deploy individual PoCs
./scripts/01-load-balancing.sh
./scripts/02-caching.sh
# ... and so on
```

---

## Architecture Concepts Overview

| # | Concept | Component | What You'll Learn |
|---|---------|-----------|-------------------|
| 1 | **Load Balancing** | NGINX Ingress | Distribute traffic across multiple pods |
| 2 | **Caching** | Redis | Reduce latency with in-memory cache |
| 3 | **CDN** | MinIO + NGINX | Edge caching for static assets |
| 4 | **Message Queue** | RabbitMQ | Asynchronous task processing |
| 5 | **Pub/Sub** | Apache Kafka | Event-driven architecture |
| 6 | **API Gateway** | Apache APISIX | Unified API entry point |
| 7 | **Circuit Breaker** | Python / Resilience4j / Polly | Fault tolerance patterns |
| 8 | **Service Discovery** | Kubernetes DNS | Automatic service resolution |
| 9 | **Sharding** | CockroachDB | Horizontal data partitioning |
| 10 | **Rate Limiting** | NGINX Ingress | API throttling |
| 11 | **Consistent Hashing** | Hazelcast | Efficient data distribution |
| 12 | **Auto Scaling** | K8s HPA | Dynamic resource allocation |

---

## PoC Details

### PoC 0: Cluster Setup

**Purpose**: Create a multi-node Kubernetes cluster with essential infrastructure.

**What It Does**:
- Creates a Kind cluster with 1 control-plane + 3 worker nodes
- Installs metrics-server (required for HPA/Auto Scaling)
- Installs NGINX Ingress Controller
- Creates the `poc-arch` namespace

**Run**:
```bash
./scripts/00-setup-cluster.sh
```

**Verify**:
```bash
kubectl get nodes
kubectl get pods -n ingress-nginx
kubectl get pods -n kube-system | grep metrics
```

**Key Learning**: Understanding Kubernetes cluster topology and essential components.

---

### PoC 1: Load Balancing

**Concept**: Distribute incoming requests across multiple backend pods to improve availability and performance.

```
                    ┌─────────────┐
                    │   Ingress   │
                    │   (NGINX)   │
                    └──────┬──────┘
                           │ Round Robin
           ┌───────────────┼───────────────┐
           ▼               ▼               ▼
    ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
    │   Pod 1     │ │   Pod 2     │ │   Pod 3     │
    │ echo-server │ │ echo-server │ │ echo-server │
    └─────────────┘ └─────────────┘ └─────────────┘
```

**Components**:
- 3 replicas of `hashicorp/http-echo` (each returns its pod name)
- NGINX Ingress with `round_robin` load balancing

**Run**:
```bash
./scripts/01-load-balancing.sh
```

**Verify**:
```bash
# Option 1: Port-forward
kubectl port-forward svc/echo-service -n poc-arch 8080:80 &

# Send 10 requests and observe different pod names
for i in $(seq 1 10); do curl -s http://localhost:8080/; echo ""; done
```

**Expected Output**:
```
echo-server-abc12
echo-server-def34
echo-server-ghi56
echo-server-abc12
...
```

**Key Learning**: Each request goes to a different pod, demonstrating round-robin load balancing.

---

### PoC 2: Caching

**Concept**: Store frequently accessed data in memory to reduce latency and database load.

```
┌────────────┐      ┌───────────────┐      ┌──────────────┐
│   Client   │ ───► │  Cache Demo   │ ───► │    Redis     │
└────────────┘      │     App       │      │   (Cache)    │
                    └───────┬───────┘      └──────────────┘
                            │ Cache Miss
                            ▼
                    ┌───────────────┐
                    │   Database    │
                    │  (Simulated)  │
                    └───────────────┘
```

**Components**:
- Redis 7 (in-memory cache)
- Python demo app with cache-aside pattern

**How It Works**:
1. First request: Cache MISS → Query database (2 second delay) → Store in cache
2. Subsequent requests: Cache HIT → Return instantly from Redis

**Run**:
```bash
./scripts/02-caching.sh
```

**Verify**:
```bash
kubectl port-forward svc/cache-demo -n poc-arch 8081:80 &

# First request (Cache MISS) - ~2 seconds
curl -s http://localhost:8081/product-123 | jq .

# Second request (Cache HIT) - ~1 millisecond
curl -s http://localhost:8081/product-123 | jq .
```

**Expected Output**:
```json
// First request
{
  "key": "product-123",
  "value": "data-for-product-123",
  "source": "DATABASE",
  "latency_ms": 2003.45
}

// Second request
{
  "key": "product-123",
  "value": "data-for-product-123",
  "source": "CACHE",
  "latency_ms": 1.23
}
```

**Key Learning**: Caching dramatically reduces response time (2000ms → 1ms).

---

### PoC 3: CDN (Content Delivery Network)

**Concept**: Cache static assets at edge locations to reduce latency and origin server load.

```
                     ┌─────────────────┐
                     │     Client      │
                     └────────┬────────┘
                              │
                     ┌────────▼────────┐
                     │   NGINX Edge    │
                     │  (Edge Cache)   │
                     │ X-Cache: HIT/MISS│
                     └────────┬────────┘
                              │ (if MISS)
                     ┌────────▼────────┐
                     │     MinIO       │
                     │ (Origin Server) │
                     └─────────────────┘
```

**Components**:
- MinIO: Object storage simulating an origin server
- NGINX: Edge cache node

**Run**:
```bash
./scripts/03-cdn.sh
```

**Verify**:
```bash
# 1. Access MinIO Console to upload test files
kubectl port-forward svc/minio-origin -n poc-arch 9001:9001 &
# Open http://localhost:9001 (login: minioadmin/minioadmin)
# Create bucket "static" and upload a file

# 2. Access via CDN Edge
kubectl port-forward svc/cdn-edge -n poc-arch 8082:80 &
curl -sI http://localhost:8082/static/test.txt | grep X-Cache
# First request: X-Cache-Status: MISS
# Second request: X-Cache-Status: HIT
```

**Key Learning**: CDN edge nodes cache content, reducing origin load and latency.

---

### PoC 4: Message Queue

**Concept**: Asynchronous communication between services using message queues for decoupling and reliability.

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   Producer   │ ──► │  RabbitMQ    │ ──► │  Consumer 1  │
│  (20 msgs)   │     │   Queue:     │     │              │
└──────────────┘     │   orders     │     ├──────────────┤
                     │              │ ──► │  Consumer 2  │
                     │              │     │              │
                     │              │     ├──────────────┤
                     │              │ ──► │  Consumer 3  │
                     └──────────────┘     └──────────────┘
```

**Components**:
- RabbitMQ with Management UI
- Python Producer (sends 20 order messages)
- 3 Python Consumers (competing consumers pattern)

**Run**:
```bash
./scripts/04-message-queue.sh
```

**Verify**:
```bash
# 1. Open RabbitMQ Management UI
kubectl port-forward svc/rabbitmq -n poc-arch 15672:15672 &
# Open http://localhost:15672 (guest/guest)

# 2. Run producer
kubectl run mq-producer --rm -it --restart=Never -n poc-arch \
  --image=python:3.11-slim \
  --overrides='{"spec":{"volumes":[{"name":"code","configMap":{"name":"mq-producer"}}],"containers":[{"name":"mq-producer","image":"python:3.11-slim","command":["sh","-c","pip install pika -q && python /app/producer.py"],"volumeMounts":[{"name":"code","mountPath":"/app"}]}]}}'

# 3. Watch consumers process messages
kubectl logs -l app=mq-consumer -n poc-arch -f --max-log-requests=5
```

**Key Learning**: Messages are distributed among competing consumers for parallel processing.

---

### PoC 5: Publish-Subscribe

**Concept**: Multiple subscribers receive copies of the same message (fan-out pattern).

```
                     ┌─────────────────┐
                     │    Producer     │
                     └────────┬────────┘
                              │
                     ┌────────▼────────┐
                     │     Kafka       │
                     │  Topic: events  │
                     │  (3 partitions) │
                     └────────┬────────┘
                              │
            ┌─────────────────┼─────────────────┐
            ▼                 ▼                 ▼
    ┌───────────────┐ ┌───────────────┐
    │ Consumer      │ │ Consumer      │
    │ Group A       │ │ Group B       │
    │ (gets ALL)    │ │ (gets ALL)    │
    └───────────────┘ └───────────────┘
```

**Difference from Message Queue**:
- **Message Queue**: One message → One consumer
- **Pub/Sub**: One message → All subscribers (each group gets a copy)

**Components**:
- Apache Kafka (via Strimzi Operator)
- Multiple consumer groups

**Run**:
```bash
./scripts/05-pub-sub.sh
```

**Verify**:
```bash
# Wait for Kafka to be ready
kubectl get kafka -n poc-arch

# Terminal 1: Consumer Group A
kubectl run kafka-consumer-a --rm -it --restart=Never -n poc-arch \
  --image=quay.io/strimzi/kafka:0.40.0-kafka-3.7.0 -- \
  bin/kafka-console-consumer.sh --bootstrap-server poc-kafka-kafka-bootstrap:9092 \
    --topic events --group group-a --from-beginning

# Terminal 2: Consumer Group B
kubectl run kafka-consumer-b --rm -it --restart=Never -n poc-arch \
  --image=quay.io/strimzi/kafka:0.40.0-kafka-3.7.0 -- \
  bin/kafka-console-consumer.sh --bootstrap-server poc-kafka-kafka-bootstrap:9092 \
    --topic events --group group-b --from-beginning

# Terminal 3: Producer
kubectl run kafka-producer --rm -it --restart=Never -n poc-arch \
  --image=quay.io/strimzi/kafka:0.40.0-kafka-3.7.0 -- \
  bin/kafka-console-producer.sh --bootstrap-server poc-kafka-kafka-bootstrap:9092 \
    --topic events
```

**Key Learning**: Both consumer groups receive every message (fan-out).

---

### PoC 6: API Gateway

**Concept**: Single entry point for all APIs with routing, authentication, and rate limiting.

```
                        ┌──────────────────────┐
                        │    Apache APISIX     │
                        │    (API Gateway)     │
                        │                      │
                        │  /api/users  → Auth  │
                        │  /api/orders → Auth  │
                        └──────────┬───────────┘
                                   │
               ┌───────────────────┼───────────────────┐
               ▼                                       ▼
        ┌─────────────┐                        ┌─────────────┐
        │  svc-users  │                        │ svc-orders  │
        │  (Backend)  │                        │  (Backend)  │
        └─────────────┘                        └─────────────┘
```

**Components**:
- Apache APISIX (API Gateway)
- Two backend services (users, orders)

**Run**:
```bash
./scripts/06-api-gateway.sh
```

**Verify**:
```bash
# Configure routes via Admin API
ADMIN_URL=http://localhost:30001/apisix/admin
API_KEY="edd1c9f034335f136f87ad84b625c8f1"

# Route 1: /api/users (no auth)
curl -X PUT $ADMIN_URL/routes/1 -H "X-API-KEY: $API_KEY" -d '{
  "uri": "/api/users/*",
  "upstream": {
    "type": "roundrobin",
    "nodes": { "svc-users.poc-arch.svc.cluster.local:80": 1 }
  }
}'

# Test
curl http://localhost:30000/api/users/
```

**Key Learning**: API Gateway provides unified routing, auth, and traffic management.

---

### PoC 7: Circuit Breaker

**Concept**: Prevent cascading failures by "breaking" the circuit when a downstream service fails.

```
State Machine:
                    ┌────────────────┐
       ┌──────────► │     CLOSED     │ ◄──────────────┐
       │            │  (Normal Flow) │                │
       │            └───────┬────────┘                │
       │                    │ failure_threshold       │ success
       │                    │ exceeded                │ in half-open
       │            ┌───────▼────────┐                │
       │            │      OPEN      │                │
       │            │ (Reject All)   │                │
       │            └───────┬────────┘                │
       │                    │ recovery_timeout        │
       │            ┌───────▼────────┐                │
       │            │   HALF_OPEN    │ ───────────────┘
       └────────────│ (Test Probe)   │
         failure    └────────────────┘
```

**Four Implementations**:

| Version | Language | Library | Use Case |
|---------|----------|---------|----------|
| 7a | Python | Custom | Learning fundamentals |
| 7b | Java | Resilience4j | Production (Spring Boot 3) |
| 7c | Java | Spring Cloud CB | Multi-cloud abstraction |
| 7d | .NET | Polly v8 | Production (.NET 8) |

**Run**:
```bash
# Python version (for learning)
./scripts/07-circuit-breaker.sh

# Java Resilience4j version (production)
./scripts/07b-circuit-breaker-java.sh

# Spring Cloud version (abstraction layer)
./scripts/07c-circuit-breaker-spring-cloud.sh

# .NET Polly version (production)
./scripts/07d-circuit-breaker-dotnet.sh
```

**Verify (Python version)**:
```bash
kubectl port-forward svc/cb-demo -n poc-arch 8083:80 &

# Send requests and watch state changes
for i in $(seq 1 20); do
  echo "--- Request $i ---"
  curl -s http://localhost:8083/ | jq '.circuit_state, .error // .downstream_response.status'
  sleep 1
done
```

**Expected State Transitions**:
```
CLOSED → (failures exceed threshold) → OPEN → (wait) → HALF_OPEN → CLOSED
```

**Key Learning**: Circuit breaker prevents cascading failures and provides fallback responses.

---

### PoC 8: Service Discovery

**Concept**: Services automatically discover each other without hardcoded addresses.

```
Kubernetes DNS Resolution:

┌───────────────────────────────────────────────────────────────┐
│                        CoreDNS                                │
├───────────────────────────────────────────────────────────────┤
│ provider-svc.poc-arch.svc.cluster.local → 10.96.x.x (VIP)    │
│ provider-headless.poc-arch.svc.cluster.local → [Pod IPs]     │
└───────────────────────────────────────────────────────────────┘

ClusterIP Service:           Headless Service:
┌─────────────────┐          ┌─────────────────┐
│   10.96.0.100   │          │    Pod IP 1     │
│   (Virtual IP)  │          │    Pod IP 2     │
│   K8s LB'd      │          │    Pod IP 3     │
└─────────────────┘          └─────────────────┘
```

**Components**:
- 3 provider pods
- ClusterIP Service (single VIP)
- Headless Service (returns all Pod IPs)

**Run**:
```bash
./scripts/08-service-discovery.sh
```

**Verify**:
```bash
kubectl run dns-test --rm -it --restart=Never -n poc-arch \
  --image=busybox:1.36 -- sh

# Inside the pod:
nslookup provider-svc          # Returns single VIP
nslookup provider-headless     # Returns all Pod IPs
```

**Key Learning**: K8s DNS enables automatic service discovery without hardcoded IPs.

---

### PoC 9: Sharding

**Concept**: Horizontally partition data across multiple database nodes.

```
              ┌────────────────────────────┐
              │      CockroachDB Cluster   │
              │                            │
              │  ┌─────────┐  ┌─────────┐  │
              │  │ Node 1  │  │ Node 2  │  │
              │  │ Range A │  │ Range B │  │
              │  └─────────┘  └─────────┘  │
              │       ┌─────────┐          │
              │       │ Node 3  │          │
              │       │ Range C │          │
              │       └─────────┘          │
              └────────────────────────────┘

Data Distribution (Hash-based):
customer_id=1001 → Hash → Range A (Node 1)
customer_id=2002 → Hash → Range B (Node 2)
customer_id=3003 → Hash → Range C (Node 3)
```

**Components**:
- CockroachDB (3-node cluster with automatic range-based sharding)

**Run**:
```bash
./scripts/09-sharding.sh
```

**Verify**:
```bash
# Open CockroachDB UI
kubectl port-forward svc/cockroachdb -n poc-arch 8084:8080 &
# Open http://localhost:8084

# Connect to SQL shell
kubectl exec -it cockroachdb-0 -n poc-arch -- /cockroach/cockroach sql --insecure

# Create sharded table and view distribution
CREATE DATABASE poc_shard;
USE poc_shard;
CREATE TABLE orders (
  order_id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  customer_id INT NOT NULL,
  product VARCHAR(100),
  amount DECIMAL(10,2)
);
SHOW RANGES FROM TABLE orders;
```

**Key Learning**: Data is automatically distributed across nodes based on hash ranges.

---

### PoC 10: Rate Limiting

**Concept**: Limit the number of requests a client can make within a time window.

```
                    ┌─────────────────────┐
                    │   NGINX Ingress     │
                    │                     │
                    │  limit: 5 req/sec   │
                    │  burst: 10          │
                    └──────────┬──────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
   Request 1-5           Request 6-10          Request 11+
   ✅ 200 OK             ⚠️ 200 (burst)        ❌ 429 Too Many
```

**Components**:
- NGINX Ingress with rate limiting annotations

**Run**:
```bash
./scripts/10-rate-limiting.sh
```

**Verify**:
```bash
# Add to /etc/hosts
echo '127.0.0.1 ratelimit.poc.local' | sudo tee -a /etc/hosts

# Flood with requests
for i in $(seq 1 30); do
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://ratelimit.poc.local/)
  if [ "$HTTP_CODE" = "200" ]; then
    echo "Request $i: ✅ 200 OK"
  else
    echo "Request $i: ❌ $HTTP_CODE (Rate Limited)"
  fi
done
```

**Key Learning**: Requests exceeding the limit receive 429 Too Many Requests.

---

### PoC 11: Consistent Hashing

**Concept**: Distribute data across nodes while minimizing redistribution when nodes change.

```
Hash Ring:
                        Node A
                          │
                   ┌──────┴──────┐
                   │             │
              Node C             Node B
                   │             │
                   └──────┬──────┘
                          │
                        Keys

Adding/Removing a Node:
- Traditional hash: ~100% keys redistributed
- Consistent hash: ~1/N keys redistributed (only neighbors affected)
```

**Components**:
- Hazelcast (distributed in-memory data grid)

**Run**:
```bash
./scripts/11-consistent-hashing.sh
```

**Verify**:
```bash
# Check cluster formation
kubectl logs hazelcast-0 -n poc-arch | grep -i 'members'

# Scale down and observe redistribution
kubectl scale statefulset hazelcast -n poc-arch --replicas=2
# Only ~33% of keys need to move

kubectl scale statefulset hazelcast -n poc-arch --replicas=3
```

**Key Learning**: Consistent hashing minimizes data movement when cluster size changes.

---

### PoC 12: Auto Scaling

**Concept**: Automatically adjust the number of pods based on CPU/memory utilization.

```
                   ┌───────────────────┐
                   │  metrics-server   │
                   │   (CPU metrics)   │
                   └─────────┬─────────┘
                             │
                   ┌─────────▼─────────┐
                   │        HPA        │
                   │  Target: 50% CPU  │
                   │  Min: 1, Max: 10  │
                   └─────────┬─────────┘
                             │
        ┌────────────────────┼────────────────────┐
        ▼                    ▼                    ▼
   ┌─────────┐         ┌─────────┐         ┌─────────┐
   │  Pod 1  │         │  Pod 2  │   ...   │  Pod N  │
   │  70%    │         │  65%    │         │  45%    │
   └─────────┘         └─────────┘         └─────────┘
```

**Components**:
- HPA (Horizontal Pod Autoscaler)
- metrics-server (provides CPU/memory metrics)

**Run**:
```bash
./scripts/12-auto-scaling.sh
```

**Verify**:
```bash
# Terminal 1: Watch HPA
kubectl get hpa autoscale-app -n poc-arch -w

# Terminal 2: Watch pods
watch -n 2 'kubectl get pods -l app=autoscale-app -n poc-arch'

# Terminal 3: Generate load
kubectl run load-generator --rm -it --restart=Never -n poc-arch \
  --image=busybox:1.36 -- /bin/sh -c \
  'while true; do wget -q -O- http://autoscale-app/ > /dev/null; done'
```

**Expected Behavior**:
1. Initial: 1 pod
2. Under load: Scales up to 2-5 pods (CPU > 50%)
3. Load removed: Scales down to 1 pod (after stabilization window)

**Key Learning**: HPA automatically scales based on resource utilization.

---

## Port Reference

| PoC | Service | Port-Forward Command | Local Port |
|-----|---------|---------------------|------------|
| 1 | Load Balancing | `kubectl port-forward svc/echo-service -n poc-arch 8080:80` | 8080 |
| 2 | Redis | `kubectl port-forward svc/redis -n poc-arch 6379:6379` | 6379 |
| 2 | Cache Demo | `kubectl port-forward svc/cache-demo -n poc-arch 8081:80` | 8081 |
| 3 | MinIO Console | `kubectl port-forward svc/minio-origin -n poc-arch 9001:9001` | 9001 |
| 3 | CDN Edge | `kubectl port-forward svc/cdn-edge -n poc-arch 8082:80` | 8082 |
| 4 | RabbitMQ UI | `kubectl port-forward svc/rabbitmq -n poc-arch 15672:15672` | 15672 |
| 6 | APISIX Gateway | NodePort | 30000 |
| 6 | APISIX Admin | NodePort | 30001 |
| 7a | CB Python | `kubectl port-forward svc/cb-demo -n poc-arch 8083:80` | 8083 |
| 7b | CB Java | `kubectl port-forward svc/r4j-circuit-breaker -n poc-arch 8086:80` | 8086 |
| 7c | CB Spring Cloud | `kubectl port-forward svc/sccb-circuit-breaker -n poc-arch 8087:80` | 8087 |
| 7d | CB .NET | `kubectl port-forward svc/dotnet-circuit-breaker -n poc-arch 8088:80` | 8088 |
| 9 | CockroachDB UI | `kubectl port-forward svc/cockroachdb -n poc-arch 8084:8080` | 8084 |
| 12 | Auto Scale App | `kubectl port-forward svc/autoscale-app -n poc-arch 8085:80` | 8085 |

### /etc/hosts Configuration

```
127.0.0.1 lb.poc.local
127.0.0.1 ratelimit.poc.local
```

---

## Cleanup

```bash
# Delete all PoC resources
./scripts/cleanup.sh

# Delete the entire Kind cluster
kind delete cluster --name arch-poc
```

---

## Troubleshooting

### Common Issues

**1. Pod stuck in Pending**
```bash
kubectl describe pod <pod-name> -n poc-arch
# Check for resource constraints or scheduling issues
```

**2. metrics-server not working**
```bash
kubectl top nodes
# If error, check metrics-server deployment
kubectl logs -n kube-system -l k8s-app=metrics-server
```

**3. Ingress not accessible**
```bash
kubectl get pods -n ingress-nginx
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller
```

**4. Java/Gradle build slow**
- First build takes 2-5 minutes (downloading dependencies)
- Check logs: `kubectl logs -l app=r4j-circuit-breaker -n poc-arch -f`

**5. Kafka not ready**
- Kafka takes 2-3 minutes to initialize
- Check: `kubectl get kafka -n poc-arch`
- Logs: `kubectl logs -n kafka -l name=strimzi-cluster-operator`

---

## Learning Path

**Recommended Order for Beginners**:

1. **PoC 0**: Setup cluster (understand K8s basics)
2. **PoC 1**: Load Balancing (traffic distribution)
3. **PoC 2**: Caching (performance optimization)
4. **PoC 8**: Service Discovery (K8s networking)
5. **PoC 12**: Auto Scaling (resource management)
6. **PoC 7a**: Circuit Breaker Python (understand the pattern)
7. **PoC 4**: Message Queue (async processing)
8. **PoC 5**: Pub/Sub (event-driven architecture)
9. **PoC 6**: API Gateway (API management)
10. **PoC 10**: Rate Limiting (API protection)
11. **PoC 9**: Sharding (data partitioning)
12. **PoC 11**: Consistent Hashing (distributed systems)
13. **PoC 7b/7c/7d**: Production Circuit Breakers

---

## References

- [ByteByteGo System Design](https://bytebytego.com/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Kind User Guide](https://kind.sigs.k8s.io/)
- [Resilience4j](https://resilience4j.readme.io/)
- [Polly .NET](https://github.com/App-vNext/Polly)
- [Apache Kafka](https://kafka.apache.org/)
- [RabbitMQ](https://www.rabbitmq.com/)
- [Apache APISIX](https://apisix.apache.org/)
- [CockroachDB](https://www.cockroachlabs.com/)
- [Hazelcast](https://hazelcast.com/)
