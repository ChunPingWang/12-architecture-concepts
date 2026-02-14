# 埠口對應快速參考

本文件提供所有 PoC 服務的埠口對應，方便快速存取各服務。

## Port-Forward 指令總覽

| PoC | 服務名稱 | Port-Forward 指令 | 本地端口 | 說明 |
|-----|---------|-------------------|----------|------|
| 1 | 負載平衡 | `kubectl port-forward svc/echo-service -n poc-arch 8080:80` | 8080 | Echo 服務 |
| 2 | Redis | `kubectl port-forward svc/redis -n poc-arch 6379:6379` | 6379 | Redis 快取 |
| 2 | 快取 Demo | `kubectl port-forward svc/cache-demo -n poc-arch 8081:80` | 8081 | 快取演示應用 |
| 3 | MinIO Console | `kubectl port-forward svc/minio-origin -n poc-arch 9001:9001` | 9001 | 物件儲存管理介面 |
| 3 | CDN Edge | `kubectl port-forward svc/cdn-edge -n poc-arch 8082:80` | 8082 | CDN 邊緣節點 |
| 4 | RabbitMQ UI | `kubectl port-forward svc/rabbitmq -n poc-arch 15672:15672` | 15672 | 訊息佇列管理介面 |
| 5 | Kafka | (透過 kubectl exec) | - | 需使用 Kafka CLI |
| 6 | APISIX Gateway | NodePort :30000 | 30000 | API 閘道入口 |
| 6 | APISIX Admin | NodePort :30001 | 30001 | API 閘道管理 |
| 7a | 斷路器 (Python) | `kubectl port-forward svc/cb-demo -n poc-arch 8083:80` | 8083 | Python 版斷路器 |
| 7b | 斷路器 (Java) | `kubectl port-forward svc/r4j-circuit-breaker -n poc-arch 8086:80` | 8086 | Resilience4j |
| 7c | 斷路器 (Spring Cloud) | `kubectl port-forward svc/sccb-circuit-breaker -n poc-arch 8087:80` | 8087 | Spring Cloud CB |
| 7d | 斷路器 (.NET) | `kubectl port-forward svc/dotnet-circuit-breaker -n poc-arch 8088:80` | 8088 | Polly v8 |
| 8 | 服務發現 | (透過 kubectl exec) | - | DNS 查詢測試 |
| 9 | CockroachDB UI | `kubectl port-forward svc/cockroachdb -n poc-arch 8084:8080` | 8084 | 分散式資料庫 UI |
| 10 | 限流 | Ingress :80 | 80 | 需設定 hosts |
| 11 | Hazelcast | (透過 kubectl exec) | - | 一致性雜湊測試 |
| 12 | 自動擴縮 | `kubectl port-forward svc/autoscale-app -n poc-arch 8085:80` | 8085 | HPA 測試應用 |

## /etc/hosts 設定

在使用 Ingress 相關功能前，請先設定本地 hosts：

```bash
# 執行以下指令新增 hosts 設定
echo '127.0.0.1 lb.poc.local' | sudo tee -a /etc/hosts
echo '127.0.0.1 ratelimit.poc.local' | sudo tee -a /etc/hosts
```

或手動編輯 `/etc/hosts` 加入：

```
127.0.0.1 lb.poc.local
127.0.0.1 ratelimit.poc.local
```

## 常用指令

### 一次啟動多個 Port-Forward

```bash
# 背景執行多個 port-forward
kubectl port-forward svc/cache-demo -n poc-arch 8081:80 &
kubectl port-forward svc/cb-demo -n poc-arch 8083:80 &
kubectl port-forward svc/rabbitmq -n poc-arch 15672:15672 &
```

### 關閉所有 Port-Forward

```bash
pkill -f "port-forward"
```

### 檢查目前的 Port-Forward

```bash
ps aux | grep "port-forward" | grep -v grep
```

## 服務預設帳密

| 服務 | 帳號 | 密碼 |
|------|------|------|
| MinIO Console | minioadmin | minioadmin |
| RabbitMQ | guest | guest |
| APISIX Admin API Key | - | edd1c9f034335f136f87ad84b625c8f1 |
