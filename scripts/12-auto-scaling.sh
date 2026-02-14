#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  PoC 12: Auto Scaling"
echo "  元件: Kubernetes HPA + metrics-server"
echo "============================================"

NAMESPACE="poc-arch"

cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
# CPU 密集型應用
apiVersion: apps/v1
kind: Deployment
metadata:
  name: autoscale-app
  labels:
    poc: auto-scaling
spec:
  replicas: 1
  selector:
    matchLabels:
      app: autoscale-app
  template:
    metadata:
      labels:
        app: autoscale-app
    spec:
      containers:
        - name: app
          image: registry.k8s.io/hpa-example
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: autoscale-app
  labels:
    poc: auto-scaling
spec:
  selector:
    app: autoscale-app
  ports:
    - port: 80
      targetPort: 80
---
# HPA: CPU 目標 50%，1-10 副本
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: autoscale-app
  labels:
    poc: auto-scaling
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: autoscale-app
  minReplicas: 1
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - type: Pods
          value: 2
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
EOF

echo ""
echo ">>> 等待 Pod 就緒..."
kubectl wait --for=condition=ready pod -l app=autoscale-app -n $NAMESPACE --timeout=60s

echo ""
echo "============================================"
echo "  驗證 Auto Scaling"
echo "============================================"
echo ""
echo "  # Terminal 1: 監控 HPA 狀態"
echo "  kubectl get hpa autoscale-app -n $NAMESPACE -w"
echo ""
echo "  # Terminal 2: 監控 Pod 數量"
echo "  watch -n 2 'kubectl get pods -l app=autoscale-app -n $NAMESPACE'"
echo ""
echo "  # Terminal 3: 產生負載"
echo "  kubectl run load-generator --rm -it --restart=Never -n $NAMESPACE \\"
echo "    --image=busybox:1.36 -- /bin/sh -c \\"
echo "    'echo \"開始產生負載...\"; while true; do wget -q -O- http://autoscale-app/ > /dev/null; done'"
echo ""
echo "  # 約 1-2 分鐘後觀察 HPA 擴展到多個副本"
echo "  # 停止 load-generator 後，約 2-3 分鐘自動縮減"
echo ""
echo "預期結果:"
echo "  1. 初始: 1 Pod"
echo "  2. 加壓後: 自動擴展到 2-5 Pods"
echo "  3. 停壓後: 自動縮減回 1 Pod"
