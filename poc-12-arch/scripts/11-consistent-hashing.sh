#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  PoC 11: Consistent Hashing"
echo "  元件: Hazelcast"
echo "============================================"

NAMESPACE="poc-arch"

cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
# Hazelcast RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hazelcast-cluster-role
rules:
  - apiGroups: [""]
    resources: ["endpoints", "pods", "services"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: hazelcast-cluster-role-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: hazelcast-cluster-role
subjects:
  - kind: ServiceAccount
    name: default
    namespace: poc-arch
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: hazelcast
  labels:
    poc: consistent-hashing
spec:
  serviceName: hazelcast
  replicas: 3
  selector:
    matchLabels:
      app: hazelcast
  template:
    metadata:
      labels:
        app: hazelcast
    spec:
      containers:
        - name: hazelcast
          image: hazelcast/hazelcast:5.3
          ports:
            - containerPort: 5701
          env:
            - name: JAVA_OPTS
              value: "-Xmx128m -Xms128m"
            - name: HZ_CLUSTERNAME
              value: "poc-cluster"
            - name: HZ_NETWORK_JOIN_KUBERNETES_ENABLED
              value: "true"
            - name: HZ_NETWORK_JOIN_KUBERNETES_NAMESPACE
              value: "poc-arch"
            - name: HZ_NETWORK_JOIN_KUBERNETES_SERVICENAME
              value: "hazelcast"
          resources:
            limits:
              memory: 256Mi
              cpu: 250m
---
apiVersion: v1
kind: Service
metadata:
  name: hazelcast
  labels:
    poc: consistent-hashing
spec:
  clusterIP: None
  selector:
    app: hazelcast
  ports:
    - port: 5701
      targetPort: 5701
---
# Demo: 寫入資料並觀察分佈
apiVersion: v1
kind: ConfigMap
metadata:
  name: hz-demo
  labels:
    poc: consistent-hashing
data:
  demo.py: |
    """
    Consistent Hashing Demo with Hazelcast
    
    此 Demo 展示:
    1. 資料如何透過 Consistent Hashing 分佈到不同節點
    2. 當節點增減時，只有少量資料需要重新分配
    """
    import hazelcast
    import time

    print("=== Consistent Hashing Demo ===")
    print("")

    # 連接 Hazelcast 叢集
    client = hazelcast.HazelcastClient(
        cluster_name="poc-cluster",
        cluster_members=["hazelcast-0.hazelcast.poc-arch.svc.cluster.local:5701"]
    )

    # 取得分散式 Map
    data_map = client.get_map("demo-data").blocking()

    # 寫入 100 筆資料
    print(">>> 寫入 100 筆資料...")
    for i in range(100):
        data_map.put(f"key-{i:04d}", f"value-{i}")

    print(f">>> Map 大小: {data_map.size()}")
    print("")

    # 查看分區資訊
    partition_service = client._internal_partition_service
    partition_count = partition_service.get_partition_count()
    print(f">>> 分區總數: {partition_count}")

    # 查看 key 的分區分佈
    from collections import Counter
    partition_dist = Counter()
    for i in range(100):
        key = f"key-{i:04d}"
        partition_id = partition_service.get_partition_id(client._serialization_service.to_data(key))
        owner = partition_service.get_partition_owner(partition_id)
        partition_dist[str(owner)] += 1

    print("")
    print(">>> 資料在各節點的分佈:")
    for node, count in partition_dist.most_common():
        print(f"    Node {node}: {count} keys")

    print("")
    print(">>> Consistent Hashing 特性:")
    print("    - 每個 key 透過 hash 決定所屬分區")
    print("    - 分區均勻分配到叢集節點")
    print("    - 節點增減時只影響相鄰分區的資料")
    print("")
    print(">>> 嘗試 scale down 後再執行本 Demo，觀察重分配量")

    client.shutdown()

  requirements.txt: |
    hazelcast-python-client
EOF

echo ""
echo ">>> 等待 Hazelcast 就緒..."
kubectl wait --for=condition=ready pod -l app=hazelcast -n $NAMESPACE --timeout=120s 2>/dev/null || echo "Hazelcast 部署中..."

echo ""
echo "============================================"
echo "  驗證 Consistent Hashing"
echo "============================================"
echo ""
echo "  # 1. 確認叢集形成"
echo "  kubectl logs hazelcast-0 -n $NAMESPACE | grep -i 'members'"
echo ""
echo "  # 2. 執行 Demo"
echo "  kubectl run hz-demo --rm -it --restart=Never -n $NAMESPACE \\"
echo "    --image=python:3.11-slim -- bash -c \\"
echo "    'pip install hazelcast-python-client -q && python /app/demo.py'"
echo "  # (需要掛載 ConfigMap)"
echo ""
echo "  # 3. Scale down 後觀察"
echo "  kubectl scale statefulset hazelcast -n $NAMESPACE --replicas=2"
echo "  # 等待穩定後再次執行 Demo"
echo "  kubectl scale statefulset hazelcast -n $NAMESPACE --replicas=3"
echo ""
echo "預期結果: 節點減少時，只有 ~1/N 的資料需要重分配"
