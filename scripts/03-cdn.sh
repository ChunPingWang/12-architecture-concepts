#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  PoC 3: Content Delivery Network (模擬)"
echo "  元件: MinIO (Origin) + NGINX (Edge Cache)"
echo "============================================"

NAMESPACE="poc-arch"

cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
# --- MinIO (模擬 Origin Server) ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio-origin
  labels:
    poc: cdn
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio-origin
  template:
    metadata:
      labels:
        app: minio-origin
    spec:
      containers:
        - name: minio
          image: minio/minio:latest
          args: ["server", "/data", "--console-address", ":9001"]
          env:
            - name: MINIO_ROOT_USER
              value: "minioadmin"
            - name: MINIO_ROOT_PASSWORD
              value: "minioadmin"
          ports:
            - containerPort: 9000
            - containerPort: 9001
          resources:
            limits:
              memory: 256Mi
              cpu: 250m
---
apiVersion: v1
kind: Service
metadata:
  name: minio-origin
  labels:
    poc: cdn
spec:
  selector:
    app: minio-origin
  ports:
    - name: api
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
---
# --- NGINX Edge Cache (模擬 CDN 邊緣節點) ---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-edge-config
  labels:
    poc: cdn
data:
  nginx.conf: |
    worker_processes auto;
    events { worker_connections 1024; }

    http {
      proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=cdn_cache:10m max_size=100m inactive=60m;
      
      log_format cdn '$remote_addr - [$time_local] "$request" $status '
                     'cache_status=$upstream_cache_status latency=${request_time}s';

      server {
        listen 80;
        access_log /var/log/nginx/access.log cdn;

        location / {
          proxy_pass http://minio-origin:9000;
          proxy_cache cdn_cache;
          proxy_cache_valid 200 30m;
          proxy_cache_valid 404 1m;
          
          # 加入 Cache 狀態 Header
          add_header X-Cache-Status $upstream_cache_status always;
          add_header X-Edge-Node "edge-01" always;
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-edge
  labels:
    poc: cdn
spec:
  replicas: 2  # 模擬多個邊緣節點
  selector:
    matchLabels:
      app: nginx-edge
  template:
    metadata:
      labels:
        app: nginx-edge
    spec:
      containers:
        - name: nginx
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: config
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
            - name: cache
              mountPath: /var/cache/nginx
          resources:
            limits:
              memory: 128Mi
              cpu: 100m
      volumes:
        - name: config
          configMap:
            name: nginx-edge-config
        - name: cache
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: cdn-edge
  labels:
    poc: cdn
spec:
  selector:
    app: nginx-edge
  ports:
    - port: 80
      targetPort: 80
EOF

echo ""
echo ">>> 等待 Pod 就緒..."
kubectl wait --for=condition=ready pod -l app=minio-origin -n $NAMESPACE --timeout=90s
kubectl wait --for=condition=ready pod -l app=nginx-edge -n $NAMESPACE --timeout=60s

echo ""
echo "============================================"
echo "  驗證 CDN"
echo "============================================"
echo ""
echo "  # 1. Port-forward MinIO Console 上傳測試檔案"
echo "  kubectl port-forward svc/minio-origin -n $NAMESPACE 9001:9001 &"
echo "  # 開啟 http://localhost:9001 (minioadmin/minioadmin)"
echo "  # 建立 bucket 'static' 並上傳檔案"
echo ""
echo "  # 2. 透過 Edge 存取"
echo "  kubectl port-forward svc/cdn-edge -n $NAMESPACE 8082:80 &"
echo "  curl -sI http://localhost:8082/static/test.txt"
echo ""
echo "  # 第一次: X-Cache-Status: MISS"
echo "  # 第二次: X-Cache-Status: HIT (從 Edge Cache 回傳)"
