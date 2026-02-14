#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  PoC 7d: Circuit Breaker (.NET Core)"
echo "  元件: .NET 8 + Polly v8"
echo "        Microsoft.Extensions.Http.Resilience"
echo "============================================"

NAMESPACE="poc-arch"

# 確保 flaky-service 已部署
cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: flaky-service
  labels:
    poc: circuit-breaker
data:
  app.py: |
    from http.server import HTTPServer, BaseHTTPRequestHandler
    import random, time
    fail_rate = 0.6
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/health":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"status":"UP"}')
                return
            if random.random() < fail_rate:
                time.sleep(3)
                self.send_response(500)
                self.end_headers()
                self.wfile.write(b'{"error":"Internal Server Error"}')
            else:
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"status":"ok","data":"response from downstream"}')
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
EOF

# === .NET 8 原始碼 ===
cat <<'OUTER' | kubectl apply -n $NAMESPACE -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: dotnet-cb-source
  labels:
    poc: circuit-breaker-dotnet
data:
  # --- CircuitBreakerDemo.csproj ---
  CircuitBreakerDemo.csproj: |
    <Project Sdk="Microsoft.NET.Sdk.Web">
      <PropertyGroup>
        <TargetFramework>net8.0</TargetFramework>
        <Nullable>enable</Nullable>
        <ImplicitUsings>enable</ImplicitUsings>
      </PropertyGroup>
      <ItemGroup>
        <!-- Polly v8 + Microsoft Resilience Extensions -->
        <PackageReference Include="Microsoft.Extensions.Http.Resilience" Version="8.10.0" />
        <PackageReference Include="Microsoft.Extensions.Resilience" Version="8.10.0" />
        <PackageReference Include="Polly" Version="8.4.2" />
        <PackageReference Include="Polly.Extensions" Version="8.4.2" />

        <!-- Health Checks -->
        <PackageReference Include="AspNetCore.HealthChecks.Uris" Version="8.0.1" />

        <!-- OpenTelemetry (Polly v8 內建 Metering) -->
        <PackageReference Include="OpenTelemetry.Exporter.Prometheus.AspNetCore" Version="1.9.0-beta.2" />
      </ItemGroup>
    </Project>

  # --- appsettings.json ---
  appsettings.json: |
    {
      "Logging": {
        "LogLevel": {
          "Default": "Information",
          "Polly": "Debug",
          "Microsoft.Extensions.Http.Resilience": "Debug"
        }
      },
      "ResilienceSettings": {
        "Standard": {
          "CircuitBreaker": {
            "SamplingDuration": "00:00:30",
            "FailureRatio": 0.5,
            "MinimumThroughput": 3,
            "BreakDuration": "00:00:15"
          },
          "Timeout": {
            "Timeout": "00:00:02"
          },
          "Retry": {
            "MaxRetryAttempts": 2,
            "Delay": "00:00:00.500",
            "BackoffType": "Exponential"
          }
        },
        "Strict": {
          "CircuitBreaker": {
            "SamplingDuration": "00:00:20",
            "FailureRatio": 0.4,
            "MinimumThroughput": 2,
            "BreakDuration": "00:00:30"
          },
          "Timeout": {
            "Timeout": "00:00:01.500"
          },
          "Retry": {
            "MaxRetryAttempts": 1,
            "Delay": "00:00:00.300",
            "BackoffType": "Constant"
          }
        }
      }
    }

  # --- Program.cs ---
  Program.cs: |
    using CircuitBreakerDemo.Services;
    using CircuitBreakerDemo.Middleware;
    using Microsoft.Extensions.Http.Resilience;
    using Polly;
    using Polly.CircuitBreaker;
    using Polly.Timeout;

    var builder = WebApplication.CreateBuilder(args);

    // ==============================================
    //  方式 1: Microsoft.Extensions.Http.Resilience
    //  (標準 Resilience Handler — 推薦做法)
    // ==============================================
    builder.Services
        .AddHttpClient("DownstreamStandard", client =>
        {
            client.BaseAddress = new Uri("http://flaky-service/");
            client.Timeout = TimeSpan.FromSeconds(5);
        })
        .AddStandardResilienceHandler(options =>
        {
            // Circuit Breaker 設定
            options.CircuitBreaker.SamplingDuration = TimeSpan.FromSeconds(30);
            options.CircuitBreaker.FailureRatio = 0.5;
            options.CircuitBreaker.MinimumThroughput = 3;
            options.CircuitBreaker.BreakDuration = TimeSpan.FromSeconds(15);
            options.CircuitBreaker.ShouldHandle = args => ValueTask.FromResult(
                args.Outcome.Result?.IsSuccessStatusCode == false
                || args.Outcome.Exception is not null
            );

            // Timeout (per attempt)
            options.AttemptTimeout.Timeout = TimeSpan.FromSeconds(2);

            // Total Timeout
            options.TotalRequestTimeout.Timeout = TimeSpan.FromSeconds(10);

            // Retry
            options.Retry.MaxRetryAttempts = 2;
            options.Retry.Delay = TimeSpan.FromMilliseconds(500);
            options.Retry.BackoffType = DelayBackoffType.Exponential;
            options.Retry.ShouldHandle = args => ValueTask.FromResult(
                args.Outcome.Result?.IsSuccessStatusCode == false
                || args.Outcome.Exception is not null
            );
        });

    // ==============================================
    //  方式 2: 自訂 Polly v8 Pipeline (精細控制)
    // ==============================================
    builder.Services
        .AddHttpClient("DownstreamCustom", client =>
        {
            client.BaseAddress = new Uri("http://flaky-service/");
            client.Timeout = TimeSpan.FromSeconds(5);
        })
        .AddResilienceHandler("custom-pipeline", pipelineBuilder =>
        {
            // Circuit Breaker
            pipelineBuilder.AddCircuitBreaker(new HttpCircuitBreakerStrategyOptions
            {
                Name = "custom-circuit-breaker",
                SamplingDuration = TimeSpan.FromSeconds(20),
                FailureRatio = 0.4,
                MinimumThroughput = 2,
                BreakDuration = TimeSpan.FromSeconds(30),
                ShouldHandle = args => ValueTask.FromResult(
                    args.Outcome.Result?.IsSuccessStatusCode == false
                    || args.Outcome.Exception is not null
                ),
                OnOpened = args =>
                {
                    Console.WriteLine($"[Custom CB] ⚡ OPENED! Break duration: {args.BreakDuration}");
                    return ValueTask.CompletedTask;
                },
                OnClosed = args =>
                {
                    Console.WriteLine("[Custom CB] ✅ CLOSED - Circuit recovered");
                    return ValueTask.CompletedTask;
                },
                OnHalfOpened = args =>
                {
                    Console.WriteLine("[Custom CB] 🔄 HALF-OPEN - Testing recovery...");
                    return ValueTask.CompletedTask;
                }
            });

            // Timeout
            pipelineBuilder.AddTimeout(new HttpTimeoutStrategyOptions
            {
                Name = "custom-timeout",
                Timeout = TimeSpan.FromSeconds(2)
            });
        });

    // ==============================================
    //  方式 3: Polly v8 ResiliencePipeline (非 HTTP)
    //  適用於任意操作（DB、gRPC、MQ 等）
    // ==============================================
    builder.Services.AddResiliencePipeline("generic-pipeline", pipelineBuilder =>
    {
        pipelineBuilder
            .AddCircuitBreaker(new CircuitBreakerStrategyOptions
            {
                Name = "generic-circuit-breaker",
                SamplingDuration = TimeSpan.FromSeconds(30),
                FailureRatio = 0.5,
                MinimumThroughput = 3,
                BreakDuration = TimeSpan.FromSeconds(15),
                ShouldHandle = new PredicateBuilder().Handle<Exception>(),
                OnOpened = args =>
                {
                    Console.WriteLine($"[Generic CB] ⚡ OPENED!");
                    return ValueTask.CompletedTask;
                },
                OnClosed = args =>
                {
                    Console.WriteLine("[Generic CB] ✅ CLOSED");
                    return ValueTask.CompletedTask;
                },
                OnHalfOpened = args =>
                {
                    Console.WriteLine("[Generic CB] 🔄 HALF-OPEN");
                    return ValueTask.CompletedTask;
                }
            })
            .AddTimeout(TimeSpan.FromSeconds(2))
            .AddRetry(new Polly.Retry.RetryStrategyOptions
            {
                MaxRetryAttempts = 2,
                Delay = TimeSpan.FromMilliseconds(500),
                BackoffType = DelayBackoffType.Exponential,
                ShouldHandle = new PredicateBuilder().Handle<Exception>()
            });
    });

    // Services
    builder.Services.AddSingleton<CircuitBreakerTracker>();
    builder.Services.AddScoped<DownstreamService>();

    // Health Checks
    builder.Services.AddHealthChecks()
        .AddUrlGroup(new Uri("http://flaky-service/health"), "downstream-service");

    var app = builder.Build();

    // ==============================================
    //  API 端點
    // ==============================================

    // --- 方式 1: Standard Resilience Handler ---
    app.MapGet("/api/call", async (DownstreamService svc) =>
    {
        var result = await svc.CallWithStandardResilience();
        return Results.Ok(result);
    });

    // --- 方式 2: Custom Polly Pipeline ---
    app.MapGet("/api/call-custom", async (DownstreamService svc) =>
    {
        var result = await svc.CallWithCustomPipeline();
        return Results.Ok(result);
    });

    // --- 方式 3: Generic Pipeline (非 HTTP) ---
    app.MapGet("/api/call-generic", async (DownstreamService svc) =>
    {
        var result = await svc.CallWithGenericPipeline();
        return Results.Ok(result);
    });

    // --- Dashboard ---
    app.MapGet("/api/dashboard", (CircuitBreakerTracker tracker) =>
    {
        return Results.Ok(tracker.GetDashboard());
    });

    // --- Health Check ---
    app.MapHealthChecks("/health");

    Console.WriteLine("============================================");
    Console.WriteLine("  .NET 8 Circuit Breaker PoC Started");
    Console.WriteLine("  Polly v8 + Microsoft.Extensions.Http.Resilience");
    Console.WriteLine("============================================");

    app.Run();

  # --- Services/DownstreamService.cs ---
  DownstreamService.cs: |
    using Polly;
    using Polly.Registry;

    namespace CircuitBreakerDemo.Services;

    public class DownstreamService
    {
        private readonly IHttpClientFactory _httpClientFactory;
        private readonly ResiliencePipelineProvider<string> _pipelineProvider;
        private readonly CircuitBreakerTracker _tracker;
        private readonly ILogger<DownstreamService> _logger;

        public DownstreamService(
            IHttpClientFactory httpClientFactory,
            ResiliencePipelineProvider<string> pipelineProvider,
            CircuitBreakerTracker tracker,
            ILogger<DownstreamService> logger)
        {
            _httpClientFactory = httpClientFactory;
            _pipelineProvider = pipelineProvider;
            _tracker = tracker;
            _logger = logger;
        }

        /// <summary>
        /// 方式 1: Standard Resilience Handler
        /// HttpClient 已內建 Circuit Breaker + Retry + Timeout
        /// </summary>
        public async Task<object> CallWithStandardResilience()
        {
            var client = _httpClientFactory.CreateClient("DownstreamStandard");
            var startTime = DateTime.UtcNow;

            try
            {
                _logger.LogInformation("[Standard] Calling downstream...");
                var response = await client.GetAsync("/");
                var content = await response.Content.ReadAsStringAsync();
                var elapsed = (DateTime.UtcNow - startTime).TotalMilliseconds;

                _tracker.RecordCall("standard", true);
                _logger.LogInformation("[Standard] Success ({Elapsed}ms)", elapsed);

                return new
                {
                    pipeline = "standard-resilience-handler",
                    status = "SUCCESS",
                    latency_ms = Math.Round(elapsed, 2),
                    response = content,
                    stats = _tracker.GetStats("standard")
                };
            }
            catch (Exception ex)
            {
                var elapsed = (DateTime.UtcNow - startTime).TotalMilliseconds;
                _tracker.RecordCall("standard", false);
                _logger.LogWarning("[Standard] FALLBACK! {Error}", ex.Message);

                var isBroken = ex is Polly.CircuitBreaker.BrokenCircuitException
                            || ex.InnerException is Polly.CircuitBreaker.BrokenCircuitException;

                return new
                {
                    pipeline = "standard-resilience-handler",
                    status = isBroken ? "CIRCUIT_OPEN" : "FALLBACK",
                    latency_ms = Math.Round(elapsed, 2),
                    error = ex.Message,
                    fallback_response = "Default/cached response from .NET fallback",
                    stats = _tracker.GetStats("standard")
                };
            }
        }

        /// <summary>
        /// 方式 2: Custom Polly v8 Pipeline (精細控制，含事件回呼)
        /// </summary>
        public async Task<object> CallWithCustomPipeline()
        {
            var client = _httpClientFactory.CreateClient("DownstreamCustom");
            var startTime = DateTime.UtcNow;

            try
            {
                _logger.LogInformation("[Custom] Calling downstream...");
                var response = await client.GetAsync("/");
                var content = await response.Content.ReadAsStringAsync();
                var elapsed = (DateTime.UtcNow - startTime).TotalMilliseconds;

                _tracker.RecordCall("custom", response.IsSuccessStatusCode);

                if (!response.IsSuccessStatusCode)
                {
                    return new
                    {
                        pipeline = "custom-polly-pipeline",
                        status = "DOWNSTREAM_ERROR",
                        http_code = (int)response.StatusCode,
                        latency_ms = Math.Round(elapsed, 2),
                        response = content,
                        stats = _tracker.GetStats("custom")
                    };
                }

                return new
                {
                    pipeline = "custom-polly-pipeline",
                    status = "SUCCESS",
                    latency_ms = Math.Round(elapsed, 2),
                    response = content,
                    stats = _tracker.GetStats("custom")
                };
            }
            catch (Exception ex)
            {
                var elapsed = (DateTime.UtcNow - startTime).TotalMilliseconds;
                _tracker.RecordCall("custom", false);

                var isBroken = ex is Polly.CircuitBreaker.BrokenCircuitException
                            || ex.InnerException is Polly.CircuitBreaker.BrokenCircuitException;

                return new
                {
                    pipeline = "custom-polly-pipeline",
                    status = isBroken ? "CIRCUIT_OPEN" : "FALLBACK",
                    latency_ms = Math.Round(elapsed, 2),
                    error = ex.Message,
                    stats = _tracker.GetStats("custom")
                };
            }
        }

        /// <summary>
        /// 方式 3: Generic ResiliencePipeline (非 HTTP 場景)
        /// 可用於 DB 查詢、gRPC 呼叫、MQ 操作等
        /// </summary>
        public async Task<object> CallWithGenericPipeline()
        {
            var pipeline = _pipelineProvider.GetPipeline("generic-pipeline");
            var startTime = DateTime.UtcNow;

            try
            {
                var result = await pipeline.ExecuteAsync(async ct =>
                {
                    _logger.LogInformation("[Generic] Executing operation...");

                    // 模擬非 HTTP 操作 (例如 DB query)
                    using var client = new HttpClient { BaseAddress = new Uri("http://flaky-service/") };
                    client.Timeout = TimeSpan.FromSeconds(5);
                    var response = await client.GetStringAsync("/", ct);
                    return response;
                });

                var elapsed = (DateTime.UtcNow - startTime).TotalMilliseconds;
                _tracker.RecordCall("generic", true);

                return new
                {
                    pipeline = "generic-resilience-pipeline",
                    status = "SUCCESS",
                    latency_ms = Math.Round(elapsed, 2),
                    response = result,
                    note = "適用於 DB / gRPC / MQ 等非 HTTP 場景",
                    stats = _tracker.GetStats("generic")
                };
            }
            catch (Exception ex)
            {
                var elapsed = (DateTime.UtcNow - startTime).TotalMilliseconds;
                _tracker.RecordCall("generic", false);

                var isBroken = ex is Polly.CircuitBreaker.BrokenCircuitException;

                return new
                {
                    pipeline = "generic-resilience-pipeline",
                    status = isBroken ? "CIRCUIT_OPEN" : "FALLBACK",
                    latency_ms = Math.Round(elapsed, 2),
                    error = ex.Message,
                    stats = _tracker.GetStats("generic")
                };
            }
        }
    }

  # --- Services/CircuitBreakerTracker.cs ---
  CircuitBreakerTracker.cs: |
    using System.Collections.Concurrent;

    namespace CircuitBreakerDemo.Services;

    /// <summary>
    /// 輕量級 CB 統計追蹤器
    /// 生產環境建議改用 OpenTelemetry Metrics
    /// </summary>
    public class CircuitBreakerTracker
    {
        private readonly ConcurrentDictionary<string, PipelineStats> _stats = new();

        public void RecordCall(string pipeline, bool success)
        {
            var stats = _stats.GetOrAdd(pipeline, _ => new PipelineStats());
            Interlocked.Increment(ref stats.TotalCalls);
            if (success)
                Interlocked.Increment(ref stats.SuccessfulCalls);
            else
                Interlocked.Increment(ref stats.FailedCalls);
        }

        public object GetStats(string pipeline)
        {
            var stats = _stats.GetOrAdd(pipeline, _ => new PipelineStats());
            var total = stats.TotalCalls;
            var failRate = total > 0 ? Math.Round((double)stats.FailedCalls / total * 100, 2) : 0;

            return new
            {
                total_calls = stats.TotalCalls,
                successful = stats.SuccessfulCalls,
                failed = stats.FailedCalls,
                failure_rate_percent = failRate
            };
        }

        public object GetDashboard()
        {
            var dashboard = new Dictionary<string, object>();
            foreach (var kvp in _stats)
            {
                dashboard[kvp.Key] = GetStats(kvp.Key);
            }

            dashboard["_info"] = new
            {
                note = "Polly v8 使用 Metering API，生產環境可透過 OpenTelemetry 匯出至 Prometheus",
                pipelines = new
                {
                    standard = "AddStandardResilienceHandler (一行搞定 CB + Retry + Timeout)",
                    custom = "AddResilienceHandler (自訂 Pipeline，精細事件回呼)",
                    generic = "AddResiliencePipeline (非 HTTP，適用 DB/gRPC/MQ)"
                }
            };

            return dashboard;
        }

        private class PipelineStats
        {
            public int TotalCalls;
            public int SuccessfulCalls;
            public int FailedCalls;
        }
    }

  # --- Middleware (placeholder for namespace) ---
  CircuitBreakerMiddleware.cs: |
    namespace CircuitBreakerDemo.Middleware;
    // Placeholder: 可在此加入全域 CB 中介層
OUTER

# === Build & Deploy ===
cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: dotnet-cb-build
  labels:
    poc: circuit-breaker-dotnet
data:
  build-and-run.sh: |
    #!/bin/bash
    set -e

    echo "============================================"
    echo "  Building .NET 8 Circuit Breaker App"
    echo "  Polly v8 + Microsoft.Extensions.Http.Resilience"
    echo "============================================"

    APP_DIR=/app/project
    SERVICES_DIR=$APP_DIR/Services
    MIDDLEWARE_DIR=$APP_DIR/Middleware

    mkdir -p $SERVICES_DIR $MIDDLEWARE_DIR

    # Copy source
    cp /source/CircuitBreakerDemo.csproj $APP_DIR/
    cp /source/appsettings.json $APP_DIR/
    cp /source/Program.cs $APP_DIR/
    cp /source/DownstreamService.cs $SERVICES_DIR/
    cp /source/CircuitBreakerTracker.cs $SERVICES_DIR/
    cp /source/CircuitBreakerMiddleware.cs $MIDDLEWARE_DIR/

    cd $APP_DIR

    echo ">>> Restoring packages..."
    dotnet restore

    echo ">>> Building..."
    dotnet build -c Release --no-restore

    echo ">>> Starting application..."
    dotnet run -c Release --no-build --urls "http://0.0.0.0:8080"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dotnet-circuit-breaker
  labels:
    poc: circuit-breaker-dotnet
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dotnet-circuit-breaker
  template:
    metadata:
      labels:
        app: dotnet-circuit-breaker
    spec:
      containers:
        - name: app
          image: mcr.microsoft.com/dotnet/sdk:8.0
          command: ['bash', '/scripts/build-and-run.sh']
          ports:
            - containerPort: 8080
          env:
            - name: ASPNETCORE_ENVIRONMENT
              value: "Development"
            - name: DOTNET_CLI_TELEMETRY_OPTOUT
              value: "1"
          resources:
            requests:
              memory: 384Mi
              cpu: 500m
            limits:
              memory: 768Mi
              cpu: "1"
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 45
            periodSeconds: 5
          volumeMounts:
            - name: source
              mountPath: /source
            - name: scripts
              mountPath: /scripts
      volumes:
        - name: source
          configMap:
            name: dotnet-cb-source
        - name: scripts
          configMap:
            name: dotnet-cb-build
            defaultMode: 0755
---
apiVersion: v1
kind: Service
metadata:
  name: dotnet-circuit-breaker
  labels:
    poc: circuit-breaker-dotnet
spec:
  selector:
    app: dotnet-circuit-breaker
  ports:
    - port: 80
      targetPort: 8080
EOF

echo ""
echo ">>> .NET 8 CB App 部署中 (首次 restore + build 約 2-3 分鐘)..."
echo ">>> 監控建置進度:"
echo "    kubectl logs -l app=dotnet-circuit-breaker -n $NAMESPACE -f"
echo ""
echo "============================================"
echo "  驗證 Circuit Breaker (.NET 8 / Polly v8)"
echo "============================================"
echo ""
echo "  kubectl port-forward svc/dotnet-circuit-breaker -n $NAMESPACE 8088:80 &"
echo ""
echo "  # =============================="
echo "  # 三種 Pipeline 模式"
echo "  # =============================="
echo ""
echo "  # 方式 1: Standard Resilience Handler (推薦，一行搞定)"
echo "  curl -s http://localhost:8088/api/call | jq ."
echo ""
echo "  # 方式 2: Custom Polly Pipeline (精細控制 + 事件回呼)"
echo "  curl -s http://localhost:8088/api/call-custom | jq ."
echo ""
echo "  # 方式 3: Generic Pipeline (非 HTTP: DB/gRPC/MQ)"
echo "  curl -s http://localhost:8088/api/call-generic | jq ."
echo ""
echo "  # Dashboard: 所有 Pipeline 統計"
echo "  curl -s http://localhost:8088/api/dashboard | jq ."
echo ""
echo "  # Health Check"
echo "  curl -s http://localhost:8088/health | jq ."
echo ""
echo "  # =============================="
echo "  # 壓測觀察狀態轉換"
echo "  # =============================="
echo ""
echo "  echo '--- Standard Pipeline ---'"
echo "  for i in \$(seq 1 20); do"
echo "    echo \"Request \$i:\""
echo "    curl -s http://localhost:8088/api/call | jq '{pipeline, status, latency_ms, stats}'"
echo "    sleep 1"
echo "  done"
echo ""
echo "  echo '--- Custom Pipeline (更嚴格) ---'"
echo "  for i in \$(seq 1 20); do"
echo "    echo \"Request \$i:\""
echo "    curl -s http://localhost:8088/api/call-custom | jq '{pipeline, status, latency_ms, stats}'"
echo "    sleep 1"
echo "  done"
echo ""
echo "  # =============================="
echo "  # 四版 Circuit Breaker 總比較"
echo "  # =============================="
echo "  #"
echo "  #  ┌──────────────┬───────────────┬──────────────────┬────────────────────┬──────────────────────┐"
echo "  #  │              │ 7a Python     │ 7b Resilience4j  │ 7c Spring Cloud CB │ 7d .NET Polly v8     │"
echo "  #  ├──────────────┼───────────────┼──────────────────┼────────────────────┼──────────────────────┤"
echo "  #  │ 語言/框架    │ Python        │ Spring Boot 3    │ Spring Boot 4      │ .NET 8 Minimal API   │"
echo "  #  │ CB 庫        │ 自製          │ Resilience4j     │ Spring Cloud CB    │ Polly v8             │"
echo "  #  │ 用途         │ 學習原理      │ 生產 (Java)      │ 多雲抽象 (Java)    │ 生產 (.NET)          │"
echo "  #  │ HTTP Client  │ urllib        │ RestTemplate     │ RestClient         │ HttpClient + DI      │"
echo "  #  │ CB 設定      │ 程式碼        │ YAML + 註解      │ YAML + Factory     │ Fluent Builder / DI  │"
echo "  #  │ Fallback     │ if/else       │ fallbackMethod   │ Lambda             │ try/catch + Pipeline │"
echo "  #  │ 非 HTTP      │ ✓ (任意)      │ ✓ (需自行包裝)   │ ✓ (Factory)        │ ✓ (Generic Pipeline) │"
echo "  #  │ 可觀測性     │ Log           │ Actuator         │ Actuator           │ OTel Metering        │"
echo "  #  │ Retry 整合   │ ✗             │ 另加註解         │ YAML 設定          │ Pipeline 內建        │"
echo "  #  │ Timeout 整合 │ ✗             │ TimeLimiter      │ TimeLimiter        │ Pipeline 內建        │"
echo "  #  └──────────────┴───────────────┴──────────────────┴────────────────────┴──────────────────────┘"
echo "  #"
echo "  #  .NET Polly v8 特色:"
echo "  #  1. AddStandardResilienceHandler() — 一行搞定 CB + Retry + Timeout + Rate Limiter"
echo "  #  2. AddResilienceHandler() — 自訂 Pipeline, 精細事件回呼 (OnOpened/OnClosed/OnHalfOpened)"
echo "  #  3. AddResiliencePipeline() — 泛用型, 適用 DB/gRPC/MQ 等非 HTTP 場景"
echo "  #  4. 原生 DI 整合, HttpClientFactory 一等公民"
echo "  #  5. OpenTelemetry Metering 內建 (不需額外 NuGet)"
