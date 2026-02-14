#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  PoC 1: Load Balancing"
echo "  元件: NGINX Ingress + 多副本後端"
echo "============================================"

NAMESPACE="poc-arch"

# 部署後端服務 (3 副本，每個回傳不同 hostname)
cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-server
  labels:
    poc: load-balancing
spec:
  replicas: 3
  selector:
    matchLabels:
      app: echo-server
  template:
    metadata:
      labels:
        app: echo-server
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:0.2.3
          args:
            - -listen=:8080
            - -text=$(POD_NAME)
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: echo-service
  labels:
    poc: load-balancing
spec:
  selector:
    app: echo-server
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo-ingress
  labels:
    poc: load-balancing
  annotations:
    nginx.ingress.kubernetes.io/load-balance: "round_robin"
spec:
  ingressClassName: nginx
  rules:
    - host: lb.poc.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: echo-service
                port:
                  number: 80
EOF

echo ""
echo ">>> 等待 Pod 就緒..."
kubectl wait --for=condition=ready pod -l app=echo-server -n $NAMESPACE --timeout=60s

echo ""
echo "============================================"
echo "  驗證 Load Balancing"
echo "============================================"
echo ""
echo "方法 1: 透過 Ingress (需設定 /etc/hosts)"
echo "  echo '127.0.0.1 lb.poc.local' >> /etc/hosts"
echo "  for i in \$(seq 1 10); do curl -s http://lb.poc.local/; done"
echo ""
echo "方法 2: 透過 port-forward"
echo "  kubectl port-forward svc/echo-service -n $NAMESPACE 8080:80 &"
echo "  for i in \$(seq 1 10); do curl -s http://localhost:8080/; done"
echo ""
echo "預期結果: 請求會被輪流分配到不同的 Pod"
