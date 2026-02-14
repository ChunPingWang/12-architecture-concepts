#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  PoC 2: Caching"
echo "  元件: Redis + Demo App"
echo "============================================"

NAMESPACE="poc-arch"

cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
# --- Redis ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  labels:
    poc: caching
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          ports:
            - containerPort: 6379
          resources:
            limits:
              memory: 128Mi
              cpu: 250m
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  labels:
    poc: caching
spec:
  selector:
    app: redis
  ports:
    - port: 6379
      targetPort: 6379
---
# --- Cache Demo App (使用 Python + Redis) ---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cache-demo-app
  labels:
    poc: caching
data:
  app.py: |
    from http.server import HTTPServer, BaseHTTPRequestHandler
    import redis
    import time
    import json
    import os

    r = redis.Redis(host='redis', port=6379, decode_responses=True)

    # 模擬慢速資料庫查詢
    def slow_db_query(key):
        time.sleep(2)  # 模擬 2 秒延遲
        return {"key": key, "value": f"data-for-{key}", "source": "DATABASE", "latency_ms": 2000}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            key = self.path.strip('/')
            if not key:
                key = "default"
            
            start = time.time()
            
            # 先查 Cache
            cached = r.get(f"cache:{key}")
            if cached:
                elapsed = (time.time() - start) * 1000
                result = json.loads(cached)
                result["source"] = "CACHE"
                result["latency_ms"] = round(elapsed, 2)
            else:
                # Cache Miss -> 查 DB
                result = slow_db_query(key)
                elapsed = (time.time() - start) * 1000
                result["latency_ms"] = round(elapsed, 2)
                # 寫入 Cache (TTL 30秒)
                r.setex(f"cache:{key}", 30, json.dumps(result))
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())

    HTTPServer(('0.0.0.0', 8080), Handler).serve_forever()

  requirements.txt: |
    redis
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cache-demo
  labels:
    poc: caching
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cache-demo
  template:
    metadata:
      labels:
        app: cache-demo
    spec:
      initContainers:
        - name: install-deps
          image: python:3.11-slim
          command: ['pip', 'install', '--target=/app/lib', 'redis']
          volumeMounts:
            - name: app-lib
              mountPath: /app/lib
      containers:
        - name: app
          image: python:3.11-slim
          command: ['python', '/app/app.py']
          env:
            - name: PYTHONPATH
              value: "/app/lib"
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: app-code
              mountPath: /app/app.py
              subPath: app.py
            - name: app-lib
              mountPath: /app/lib
      volumes:
        - name: app-code
          configMap:
            name: cache-demo-app
        - name: app-lib
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: cache-demo
  labels:
    poc: caching
spec:
  selector:
    app: cache-demo
  ports:
    - port: 80
      targetPort: 8080
EOF

echo ""
echo ">>> 等待 Pod 就緒..."
kubectl wait --for=condition=ready pod -l app=redis -n $NAMESPACE --timeout=60s
kubectl wait --for=condition=ready pod -l app=cache-demo -n $NAMESPACE --timeout=120s

echo ""
echo "============================================"
echo "  驗證 Caching"
echo "============================================"
echo ""
echo "  kubectl port-forward svc/cache-demo -n $NAMESPACE 8081:80 &"
echo ""
echo "  # 第一次請求 (Cache Miss) - 約 2 秒"
echo "  curl -s http://localhost:8081/product-123 | jq ."
echo ""
echo "  # 第二次請求 (Cache Hit) - 約 1 毫秒"
echo "  curl -s http://localhost:8081/product-123 | jq ."
echo ""
echo "預期結果: 第一次 source=DATABASE, 第二次 source=CACHE，延遲差異明顯"
