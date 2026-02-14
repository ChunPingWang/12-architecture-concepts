#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  PoC 10: Rate Limiting"
echo "  元件: NGINX Ingress Rate Limiting"
echo "============================================"

NAMESPACE="poc-arch"

cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rate-limit-backend
  labels:
    poc: rate-limiting
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rate-limit-backend
  template:
    metadata:
      labels:
        app: rate-limit-backend
    spec:
      containers:
        - name: app
          image: hashicorp/http-echo:0.2.3
          args: ["-listen=:8080", "-text={\"status\":\"ok\",\"message\":\"Request accepted\"}"]
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: rate-limit-backend
spec:
  selector:
    app: rate-limit-backend
  ports:
    - port: 80
      targetPort: 8080
---
# Rate Limited Ingress (5 req/sec)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rate-limited-api
  labels:
    poc: rate-limiting
  annotations:
    nginx.ingress.kubernetes.io/limit-rps: "5"
    nginx.ingress.kubernetes.io/limit-burst-multiplier: "2"
    nginx.ingress.kubernetes.io/limit-connections: "10"
    nginx.ingress.kubernetes.io/custom-http-errors: "429"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      more_set_headers "X-RateLimit-Limit: 5";
spec:
  ingressClassName: nginx
  rules:
    - host: ratelimit.poc.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: rate-limit-backend
                port:
                  number: 80
EOF

echo ""
echo "============================================"
echo "  驗證 Rate Limiting"
echo "============================================"
echo ""
echo "  echo '127.0.0.1 ratelimit.poc.local' >> /etc/hosts"
echo ""
echo "  # 壓測: 每秒 20 個請求 (限制 5/s)"
echo "  for i in \$(seq 1 30); do"
echo "    HTTP_CODE=\$(curl -s -o /dev/null -w '%{http_code}' http://ratelimit.poc.local/)"
echo "    if [ \"\$HTTP_CODE\" = \"200\" ]; then"
echo "      echo \"Request \$i: ✅ 200 OK\""
echo "    else"
echo "      echo \"Request \$i: ❌ \$HTTP_CODE (Rate Limited)\""
echo "    fi"
echo "  done"
echo ""
echo "  # 或使用 hey 壓測工具"
echo "  # hey -n 100 -c 20 -q 20 http://ratelimit.poc.local/"
echo ""
echo "預期結果: 前幾個請求 200，超頻後收到 429 Too Many Requests"
