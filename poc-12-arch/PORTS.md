# Port Mapping 快速參考

| PoC | 服務 | Port-Forward 指令 | 本地端口 |
|-----|------|-------------------|----------|
| 1 | Load Balancing | `kubectl port-forward svc/echo-service -n poc-arch 8080:80` | 8080 |
| 2 | Redis | `kubectl port-forward svc/redis -n poc-arch 6379:6379` | 6379 |
| 2 | Cache Demo | `kubectl port-forward svc/cache-demo -n poc-arch 8081:80` | 8081 |
| 3 | MinIO Console | `kubectl port-forward svc/minio-origin -n poc-arch 9001:9001` | 9001 |
| 3 | CDN Edge | `kubectl port-forward svc/cdn-edge -n poc-arch 8082:80` | 8082 |
| 4 | RabbitMQ UI | `kubectl port-forward svc/rabbitmq -n poc-arch 15672:15672` | 15672 |
| 5 | Kafka | (透過 kubectl exec) | - |
| 6 | APISIX Gateway | NodePort :30000 | 30000 |
| 6 | APISIX Admin | NodePort :30001 | 30001 |
| 7a | Circuit Breaker (Python) | `kubectl port-forward svc/cb-demo -n poc-arch 8083:80` | 8083 |
| 7b | Circuit Breaker (Java) | `kubectl port-forward svc/r4j-circuit-breaker -n poc-arch 8086:80` | 8086 |
| 7c | Circuit Breaker (Spring Cloud) | `kubectl port-forward svc/sccb-circuit-breaker -n poc-arch 8087:80` | 8087 |
| 7d | Circuit Breaker (.NET) | `kubectl port-forward svc/dotnet-circuit-breaker -n poc-arch 8088:80` | 8088 |
| 8 | Service Discovery | (透過 kubectl exec) | - |
| 9 | CockroachDB UI | `kubectl port-forward svc/cockroachdb -n poc-arch 8084:8080` | 8084 |
| 10 | Rate Limiting | Ingress :80 (ratelimit.poc.local) | 80 |
| 11 | Hazelcast | (透過 kubectl exec) | - |
| 12 | Auto Scaling | `kubectl port-forward svc/autoscale-app -n poc-arch 8085:80` | 8085 |

## /etc/hosts 設定

```
127.0.0.1 lb.poc.local
127.0.0.1 ratelimit.poc.local
```
