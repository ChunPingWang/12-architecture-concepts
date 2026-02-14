#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  PoC 7: Circuit Breaker"
echo "  元件: 自製 Python 斷路器 Demo"
echo "============================================"

NAMESPACE="poc-arch"

cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
# --- 不穩定的下游服務 ---
apiVersion: v1
kind: ConfigMap
metadata:
  name: flaky-service
  labels:
    poc: circuit-breaker
data:
  app.py: |
    from http.server import HTTPServer, BaseHTTPRequestHandler
    import random
    import time

    fail_rate = 0.6  # 60% 失敗率

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if random.random() < fail_rate:
                time.sleep(3)  # 模擬超時
                self.send_response(500)
                self.end_headers()
                self.wfile.write(b'{"error": "Internal Server Error"}')
            else:
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"status": "ok", "data": "response from downstream"}')

    HTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flaky-service
  labels:
    poc: circuit-breaker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: flaky-service
  template:
    metadata:
      labels:
        app: flaky-service
    spec:
      containers:
        - name: app
          image: python:3.11-slim
          command: ['python', '/app/app.py']
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: code
              mountPath: /app
      volumes:
        - name: code
          configMap:
            name: flaky-service
---
apiVersion: v1
kind: Service
metadata:
  name: flaky-service
spec:
  selector:
    app: flaky-service
  ports:
    - port: 80
      targetPort: 8080
---
# --- Circuit Breaker 上游服務 ---
apiVersion: v1
kind: ConfigMap
metadata:
  name: circuit-breaker-app
  labels:
    poc: circuit-breaker
data:
  app.py: |
    from http.server import HTTPServer, BaseHTTPRequestHandler
    import urllib.request
    import json
    import time
    import threading

    class CircuitBreaker:
        CLOSED = "CLOSED"
        OPEN = "OPEN"
        HALF_OPEN = "HALF_OPEN"

        def __init__(self, failure_threshold=3, recovery_timeout=10, half_open_max=2):
            self.state = self.CLOSED
            self.failure_count = 0
            self.success_count = 0
            self.failure_threshold = failure_threshold
            self.recovery_timeout = recovery_timeout
            self.half_open_max = half_open_max
            self.last_failure_time = None
            self.lock = threading.Lock()

        def call(self, func):
            with self.lock:
                if self.state == self.OPEN:
                    if time.time() - self.last_failure_time > self.recovery_timeout:
                        print(f"[CB] OPEN -> HALF_OPEN (嘗試恢復)")
                        self.state = self.HALF_OPEN
                        self.success_count = 0
                    else:
                        remaining = self.recovery_timeout - (time.time() - self.last_failure_time)
                        print(f"[CB] OPEN - 拒絕請求 (剩餘 {remaining:.1f}s)")
                        return None, "Circuit is OPEN - request rejected"

            try:
                result = func()
                with self.lock:
                    if self.state == self.HALF_OPEN:
                        self.success_count += 1
                        print(f"[CB] HALF_OPEN 成功 ({self.success_count}/{self.half_open_max})")
                        if self.success_count >= self.half_open_max:
                            print(f"[CB] HALF_OPEN -> CLOSED (恢復正常)")
                            self.state = self.CLOSED
                            self.failure_count = 0
                    elif self.state == self.CLOSED:
                        self.failure_count = 0
                return result, None
            except Exception as e:
                with self.lock:
                    self.failure_count += 1
                    self.last_failure_time = time.time()
                    print(f"[CB] 失敗 ({self.failure_count}/{self.failure_threshold}) - {e}")
                    if self.failure_count >= self.failure_threshold:
                        print(f"[CB] {self.state} -> OPEN (達到失敗閾值)")
                        self.state = self.OPEN
                return None, str(e)

    cb = CircuitBreaker(failure_threshold=3, recovery_timeout=15, half_open_max=2)

    def call_downstream():
        req = urllib.request.urlopen("http://flaky-service/", timeout=2)
        if req.status != 200:
            raise Exception(f"HTTP {req.status}")
        return req.read().decode()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            result, error = cb.call(call_downstream)
            response = {
                "circuit_state": cb.state,
                "failure_count": cb.failure_count,
            }
            if error:
                response["error"] = error
                response["fallback"] = "cached/default response"
                self.send_response(503)
            else:
                response["downstream_response"] = json.loads(result)
                self.send_response(200)
            
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response, indent=2).encode())

    print("[CB App] Starting with Circuit Breaker (threshold=3, recovery=15s)")
    HTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cb-demo
  labels:
    poc: circuit-breaker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cb-demo
  template:
    metadata:
      labels:
        app: cb-demo
    spec:
      containers:
        - name: app
          image: python:3.11-slim
          command: ['python', '/app/app.py']
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: code
              mountPath: /app
      volumes:
        - name: code
          configMap:
            name: circuit-breaker-app
---
apiVersion: v1
kind: Service
metadata:
  name: cb-demo
spec:
  selector:
    app: cb-demo
  ports:
    - port: 80
      targetPort: 8080
EOF

echo ""
echo ">>> 等待 Pod 就緒..."
kubectl wait --for=condition=ready pod -l app=cb-demo -n $NAMESPACE --timeout=60s

echo ""
echo "============================================"
echo "  驗證 Circuit Breaker"
echo "============================================"
echo ""
echo "  kubectl port-forward svc/cb-demo -n $NAMESPACE 8083:80 &"
echo ""
echo "  # 連續發送請求，觀察斷路器狀態變化"
echo "  for i in \$(seq 1 20); do"
echo "    echo \"--- Request \$i ---\""
echo "    curl -s http://localhost:8083/ | jq '.circuit_state, .error // .downstream_response.status'"
echo "    sleep 1"
echo "  done"
echo ""
echo "  # 觀察日誌"
echo "  kubectl logs -l app=cb-demo -n $NAMESPACE -f"
echo ""
echo "預期結果: CLOSED -> (連續失敗) -> OPEN -> (等待) -> HALF_OPEN -> CLOSED"
