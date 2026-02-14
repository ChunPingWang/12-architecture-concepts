#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  PoC 6: API Gateway"
echo "  元件: Apache APISIX"
echo "============================================"

NAMESPACE="poc-arch"

# 使用 Helm 安裝 APISIX
echo ">>> 安裝 Apache APISIX..."
helm repo add apisix https://charts.apiseven.com 2>/dev/null || true
helm repo update 2>/dev/null || true

helm upgrade --install apisix apisix/apisix \
  --namespace $NAMESPACE \
  --set gateway.type=NodePort \
  --set gateway.http.nodePort=30000 \
  --set admin.type=NodePort \
  --set admin.nodePort=30001 \
  --set etcd.replicaCount=1 \
  --set etcd.persistence.enabled=false \
  --wait --timeout 180s 2>/dev/null || echo "APISIX 部署中..."

# 部署兩個後端服務
cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
# --- Service A: Users ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: svc-users
  labels:
    poc: api-gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: svc-users
  template:
    metadata:
      labels:
        app: svc-users
    spec:
      containers:
        - name: app
          image: hashicorp/http-echo:0.2.3
          args: ["-listen=:8080", "-text={\"service\":\"users\",\"data\":[{\"id\":1,\"name\":\"Alice\"},{\"id\":2,\"name\":\"Bob\"}]}"]
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: svc-users
spec:
  selector:
    app: svc-users
  ports:
    - port: 80
      targetPort: 8080
---
# --- Service B: Orders ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: svc-orders
  labels:
    poc: api-gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: svc-orders
  template:
    metadata:
      labels:
        app: svc-orders
    spec:
      containers:
        - name: app
          image: hashicorp/http-echo:0.2.3
          args: ["-listen=:8080", "-text={\"service\":\"orders\",\"data\":[{\"id\":1001,\"amount\":99.99}]}"]
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: svc-orders
spec:
  selector:
    app: svc-orders
  ports:
    - port: 80
      targetPort: 8080
EOF

echo ""
echo "============================================"
echo "  設定 APISIX 路由"
echo "============================================"
echo ""
echo "  # 設定路由 (APISIX Admin API)"
echo "  ADMIN_URL=http://localhost:30001/apisix/admin"
echo "  API_KEY=\"edd1c9f034335f136f87ad84b625c8f1\"  # 預設 key"
echo ""
echo "  # 路由 /api/users -> svc-users"
echo "  curl -X PUT \$ADMIN_URL/routes/1 -H \"X-API-KEY: \$API_KEY\" -d '"
echo '  {
    "uri": "/api/users/*",
    "upstream": {
      "type": "roundrobin",
      "nodes": { "svc-users.poc-arch.svc.cluster.local:80": 1 }
    },
    "plugins": {
      "proxy-rewrite": { "regex_uri": ["^/api/users/(.*)", "/$1"] }
    }
  }'"'"
echo ""
echo "  # 路由 /api/orders -> svc-orders"
echo "  curl -X PUT \$ADMIN_URL/routes/2 -H \"X-API-KEY: \$API_KEY\" -d '"
echo '  {
    "uri": "/api/orders/*",
    "upstream": {
      "type": "roundrobin",
      "nodes": { "svc-orders.poc-arch.svc.cluster.local:80": 1 }
    },
    "plugins": {
      "proxy-rewrite": { "regex_uri": ["^/api/orders/(.*)", "/$1"] },
      "key-auth": {}
    }
  }'"'"
echo ""
echo "  # 測試"
echo "  curl http://localhost:30000/api/users/"
echo "  curl http://localhost:30000/api/orders/  # 401 (需認證)"
