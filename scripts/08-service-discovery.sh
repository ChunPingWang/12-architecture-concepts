#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  PoC 8: Service Discovery"
echo "  元件: Kubernetes DNS (CoreDNS)"
echo "============================================"

NAMESPACE="poc-arch"

cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
# --- Provider Service (Headless for DNS Discovery) ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: provider
  labels:
    poc: service-discovery
spec:
  replicas: 3
  selector:
    matchLabels:
      app: provider
  template:
    metadata:
      labels:
        app: provider
    spec:
      containers:
        - name: nginx
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
---
# 標準 ClusterIP Service
apiVersion: v1
kind: Service
metadata:
  name: provider-svc
  labels:
    poc: service-discovery
spec:
  selector:
    app: provider
  ports:
    - port: 80
      targetPort: 80
---
# Headless Service (直接解析到 Pod IP)
apiVersion: v1
kind: Service
metadata:
  name: provider-headless
  labels:
    poc: service-discovery
spec:
  clusterIP: None
  selector:
    app: provider
  ports:
    - port: 80
      targetPort: 80
---
# --- Consumer: DNS Discovery Demo ---
apiVersion: v1
kind: ConfigMap
metadata:
  name: discovery-demo
  labels:
    poc: service-discovery
data:
  discover.sh: |
    #!/bin/sh
    echo "============================================"
    echo "  Kubernetes Service Discovery Demo"
    echo "============================================"
    echo ""
    
    echo ">>> 1. ClusterIP Service DNS 解析"
    echo "    provider-svc.poc-arch.svc.cluster.local"
    nslookup provider-svc.poc-arch.svc.cluster.local 2>/dev/null || dig provider-svc.poc-arch.svc.cluster.local +short
    echo ""
    
    echo ">>> 2. Headless Service DNS 解析 (回傳所有 Pod IP)"
    echo "    provider-headless.poc-arch.svc.cluster.local"
    nslookup provider-headless.poc-arch.svc.cluster.local 2>/dev/null || dig provider-headless.poc-arch.svc.cluster.local +short
    echo ""
    
    echo ">>> 3. SRV 記錄查詢"
    nslookup -type=SRV _http._tcp.provider-headless.poc-arch.svc.cluster.local 2>/dev/null || \
      dig SRV _http._tcp.provider-headless.poc-arch.svc.cluster.local +short
    echo ""
    
    echo ">>> 4. 短名稱解析 (同 Namespace)"
    nslookup provider-svc 2>/dev/null
    echo ""
    
    echo ">>> 5. 環境變數方式 (K8s 注入)"
    env | grep -i PROVIDER || echo "  (無相關環境變數 - 服務可能在 Pod 之後建立)"
    echo ""
    
    echo ">>> 6. 逐一 curl 所有 Provider Pod"
    for ip in $(nslookup provider-headless.poc-arch.svc.cluster.local 2>/dev/null | grep "Address" | tail -n +2 | awk '{print $2}'); do
      echo "  -> Calling $ip ..."
      curl -s -o /dev/null -w "    HTTP %{http_code} from $ip (latency: %{time_total}s)\n" http://$ip/ || echo "    Failed"
    done
    
    echo ""
    echo ">>> 結論: K8s 透過 CoreDNS 自動追蹤服務端點"
    echo "    - ClusterIP: 單一虛擬 IP，K8s 負責負載平衡"
    echo "    - Headless: 直接取得所有 Pod IP，client-side LB"
EOF

echo ""
echo ">>> 等待 Provider 就緒..."
kubectl wait --for=condition=ready pod -l app=provider -n $NAMESPACE --timeout=60s

echo ""
echo "============================================"
echo "  驗證 Service Discovery"
echo "============================================"
echo ""
echo "  kubectl run discovery-test --rm -it --restart=Never -n $NAMESPACE \\"
echo "    --image=busybox:1.36 -- sh /app/discover.sh \\"
echo "    --overrides='{\"spec\":{\"volumes\":[{\"name\":\"code\",\"configMap\":{\"name\":\"discovery-demo\",\"defaultMode\":493}}],\"containers\":[{\"name\":\"discovery-test\",\"image\":\"busybox:1.36\",\"command\":[\"sh\",\"/app/discover.sh\"],\"volumeMounts\":[{\"name\":\"code\",\"mountPath\":\"/app\"}]}]}}'"
echo ""
echo "  # 簡易版"
echo "  kubectl run dns-test --rm -it --restart=Never -n $NAMESPACE --image=busybox:1.36 -- nslookup provider-headless"
