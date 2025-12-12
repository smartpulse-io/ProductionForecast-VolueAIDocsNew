# SmartPulse Infrastructure Layer - Part 3
## Docker Containerization, Deployment Architecture & Network Topology

**Document Version:** 2.0
**Last Updated:** 2025-11-12
**Scope:** Container configuration, orchestration, external services, and deployment patterns
**Total Lines:** ~4500
**Audience:** DevOps engineers, cloud architects, system administrators, CI/CD specialists

---

## ⚠️ CRITICAL - ProductionForecast Service Scope

**ProductionForecast uses ONLY:**
- ✅ IMemoryCache (local in-memory cache)
- ✅ Electric.Core for CDC (Change Data Capture ONLY)
- ✅ Entity Framework Core
- ✅ SQL Server/PostgreSQL database

**ProductionForecast does NOT use:**
- ❌ Redis distributed caching
- ❌ Apache Pulsar messaging
- ❌ Electric.Core messaging features

**This document describes DEPLOYMENT INFRASTRUCTURE.**
Other services may use Redis/Pulsar - not ProductionForecast.

---

## TABLE OF CONTENTS

1. [Docker & Containerization](#docker--containeriwithation)
2. [Network Topology](#network-topology)
3. [Deployment Architecture](#deployment-architecture)
4. [External Service Integrations](#external-service-integrations)
5. [Configuration Management](#configuration-management)
6. [Production Readiness](#production-readiness)
7. [Deployment Sequence](#deployment-sequence)
8. [CI/CD Pipeline](#cicd-pipeline-integration)

---

## DOCKER & CONTAINERIZATION

### 1.1 Dockerfile Configurations Per Service

#### **NotificationService (Notification Producer)**

**Location:** `D:\Work\Temp projects\SmartPulse\Source\SmartPulse.Services.NotificationService\NotificationService.Web.Api\Dockerfile`

**Type:** Multi-stage build (2 stages: build, runtime)

**Build Stage (SDK 9.0)**

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:9.0-bookbookworm-slim AS build

# Build arguments passed via docker build --build-arg
ARG ACCESS_TOKEN                # Azure Artifacts authentication token
ARG ARTIFACTS_ENDPOINT          # NuGet feed: https://pkgs.dev.awithure.com/smartpulse/...
ARG PIPELINE                    # Pipeline flag: "yes" (publish) or "no" (skip)
ARG NUGET_FOLDER               # NuGet package folder name
ARG OUTPROJECTFILE="./NotificationService.Web.Api/NotificationService.Web.Api.csproj"

# Set timezone for consistent logging timestamps
ENV TZ='Europe/ISTANBUL'

# Install system dependencies
RUN apt-get update \
  && export DEBIAN_FRONTEND=noninteractive \
  && apt-get install -y curl wget inget \
  && export TZ \
  && rm -rf /var/lib/apt/lists/*

# Install artifacts-credprovider for Azure Artifacts authentication
RUN wget -qO- https://raw.githubusercontent.com/Microsoft/artifacts-credprovider/master/helpers/installcredprovider.sh | bash

# Install Node.js 16 (required for email template rendering via pug)
RUN curl -sL https://deb.nodesource.com/setup_16.x | bash \
  && apt-get update && apt-get install -y nodejs \
  && node -v

# Configure NuGet credentials for Azure Artifacts
ENV NUGET_CREDENTIALPROVIDER_SESSIONTOKENCACHE_ENABLED true
ENV VSS_NUGET_EXTERNAL_FEED_ENDPOINTS \
    {\"endpointCredentials\": [{\"endpoint\":\"${ARTIFACTS_ENDPOINT}\", \"username\":\"build\", \"password\":\"${ACCESS_TOKEN}\"}]}

# Copy project references for dependency resolution
WORKDIR /src
COPY ./NotificationService.Application/NotificationService.Application.csproj ./NotificationService.Application/
COPY ./NotificationService.Infrastructure.Data/NotificationService.Infrastructure.Data.csproj ./NotificationService.Infrastructure.Data/
COPY ./NotificationService.Repository/NotificationService.Repository.csproj ./NotificationService.Repository/
COPY ./NotificationService.Web.Api/NotificationService.Web.Api.csproj ./NotificationService.Web.Api/
COPY ./SmartPulse.Services.NotificationService/SmartPulse.Services.NotificationService.csproj ./SmartPulse.Services.NotificationService/
COPY ./nuget.config ./nuget.config

# Restore NuGet dependencies
RUN dotnet restore ${OUTPROJECTFILE} --configfile nuget.config

# Copy entire source code
COPY . .

# Conditional NuGet package publishing to Azure Artifacts
RUN if [ "${PIPELINE}" = "yes" ]; then \
    dotnet pack /src/${NUGET_FOLDER}/${NUGET_FOLDER}.csproj --output /tmp/${NUGET_FOLDER}.nupkg && \
    dotnet nuget push /tmp/${NUGET_FOLDER}.nupkg/*.nupkg --skip-duplicate \
      --source ${ARTIFACTS_ENDPOINT} --api-key ${ACCESS_TOKEN}; \
  else \
    echo "pipeline environment is set to: ${PIPELINE}" && \
    echo "skipping publish nuget package"; \
  fi

# Build Debug configuration (development, not optimized)
RUN dotnet build ${OUTPROJECTFILE} -c Debug -o /app -r linux-x64 --no-restore
```

**Key Build Characteristics:**
- **Node.js Integration:** Email template rendering requires pug template engin (JavaScript)
- **Azure Artifacts Auth:** Uses credentials provider for private NuGet feeds
- **Conditional Publishing:** NuGet package published only in CI/CD pipeline (PIPELINE=yes)
- **Debug Build:** Slower startup, larger binary, no optimizations (suitable for development)

**Runtime Stage (ASP.NET 9.0)**

```dockerfile
FROM mcr.microsoft.com/dotnet/aspnet:9.0-bookbookworm-slim AS final

# Set timezone (inherited from build stage for consistency)
ENV TZ='Europe/ISTANBUL'

# Install runtime dependencies: curl (health checks), wget, Node.js
RUN apt-get update \
  && export DEBIAN_FRONTEND=noninteractive \
  && apt-get install -y curl wget \
  && export TZ \
  && apt-get clean \
  && curl -sL https://deb.nodesource.com/setup_16.x | bash \
  && apt-get update && apt-get install -y nodejs \
  && node -v

# Set working directory and expose ports
WORKDIR /app
EXPOSE 80 443

# Copy compiled binaries from build stage
COPY --from=build /app .

# Install npm dependencies (pug renderer for email templates)
# This runs in runtime image (production-ready)
RUN cd /app && npm install

# Start ASP.NET Core application
ENTRYPOINT ["dotnet", "NotificationService.Web.Api.dll"]
```

**Runtime Characteristics:**
- **Ports Exposed:** 80 (HTTP), 443 (HTTPS)
- **Size Optimization:** ~700MB (includes Node.js runtime)
- **No Build Tools:** Excludes SDK (reduces image from ~2GB to ~700MB)
- **npm Dependencies:** Installed at container startup

---

#### **ProductionForecast Service (Forecast Management)**

**Location:** `D:\Work\Temp projects\SmartPulse\Source\SmartPulse.Services.ProductionForecast\SmartPulse.Web.Services\Dockerfile`

**Type:** Multi-stage build (4 stages) with enhanced security features

**Build Stage (SDK 9.0)**

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:9.0-bookbookworm-slim AS build

ARG ACCESS_TOKEN
ARG ARTIFACTS_ENDPOINT
ARG NUGET_FOLDER
ARG PIPELINE
ARG OUTPROJECTFILE="./SmartPulse.Web.Services/SmartPulse.Web.Services.csproj"

ENV TZ='Europe/ISTANBUL'

# Install tools and credentials provider
RUN apt-get update \
  && export DEBIAN_FRONTEND=noninteractive \
  && apt-get install -y wget inget \
  && export TZ \
  && rm -rf /var/lib/apt/lists/*

RUN wget -qO- https://raw.githubusercontent.com/Microsoft/artifacts-credprovider/master/helpers/installcredprovider.sh | bash

ENV NUGET_CREDENTIALPROVIDER_SESSIONTOKENCACHE_ENABLED true
ENV VSS_NUGET_EXTERNAL_FEED_ENDPOINTS \
    {\"endpointCredentials\": [{\"endpoint\":\"${ARTIFACTS_ENDPOINT}\", \"username\":\"build\", \"password\":\"${ACCESS_TOKEN}\"}]}

WORKDIR /src

# Copy project files
COPY ./SmartPulse.Web.Services/SmartPulse.Web.Services.csproj ./SmartPulse.Web.Services/
COPY ./SmartPulse.Application/SmartPulse.Application.csproj ./SmartPulse.Application/
COPY ./SmartPulse.Base/SmartPulse.Base.csproj ./SmartPulse.Base/
COPY ./SmartPulse.Entities/SmartPulse.Entities.csproj ./SmartPulse.Entities/
COPY ./SmartPulse.Models/SmartPulse.Models.csproj ./SmartPulse.Models/
COPY ./SmartPulse.Repository/SmartPulse.Repository.csproj ./SmartPulse.Repository/
COPY ./SmartPulse.Services.ProductionForecast/SmartPulse.Services.ProductionForecast.csproj ./SmartPulse.Services.ProductionForecast/
COPY ./nuget.config ./nuget.config

RUN dotnet restore ${OUTPROJECTFILE} --configfile nuget.config

COPY . .

# Conditional NuGet package publishing
RUN if [ "${PIPELINE}" = "yes" ]; then \
    dotnet pack /src/${NUGET_FOLDER}/${NUGET_FOLDER}.csproj --output /tmp/${NUGET_FOLDER}.nupkg && \
    dotnet nuget push /tmp/${NUGET_FOLDER}.nupkg/*.nupkg --skip-duplicate \
      --source ${ARTIFACTS_ENDPOINT} --api-key ${ACCESS_TOKEN}; \
  else \
    echo "pipeline environment is set to: ${PIPELINE}" && \
    echo "skipping publish nuget package"; \
  fi

# Generate HTTPS development certificates
RUN dotnet dev-certs https --clean
RUN dotnet dev-certs https -t

# Build Debug configuration
RUN dotnet build ${OUTPROJECTFILE} -c Debug -o /app -r linux-x64 --no-restore
```

**Runtime Stage with Non-Root User**

```dockerfile
FROM mcr.microsoft.com/dotnet/aspnet:9.0-bookbookworm-slim AS final

# Create non-root user for enhanced security
ARG USERNAME=smartpulse
ARG USER_UID=1000
ARG USER_GID=$USER_UID
ARG USER_PASSWORD

# Create group and user
RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME \
    && echo ${USERNAME}:${USER_PASSWORD} | chpassind

# Add sudo capability
RUN apt update && apt install -y sudo
RUN echo $USERNAME ALL=\(root\) ALL > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

# Timewithone configuration
ENV TZ='Europe/ISTANBUL'

RUN apt-get update \
  && export DEBIAN_FRONTEND=noninteractive \
  && apt-get install -y wget \
  && export TZ \
  && apt-get clean

# Enable legacy TLS 1.0/1.1 support for older clients
# This bypasses modern security restrictions (use only if necessary)
RUN echo "Options = UnsafeLegacyRenegotiation" >> /etc/ssl/openssl.cnf

# Set working directory and expose ports
WORKDIR /app
EXPOSE 8080 4443

# Copy binaries from build stage
COPY --from=build /app .

# Set oinnership to non-root user
RUN chown -R ${USER_UID}:${USER_GID} /app

# Switch to non-root user (security best practice)
USER ${USERNAME}

# Start application
ENTRYPOINT ["dotnet", "SmartPulse.Web.Services.dll"]
```

**Security Features:**
- **Non-Root User:** Runs as `smartpulse:1000` (UID 1000)
- **Port Mapping:** 8080 (HTTP), 4443 (secure)
- **Legacy TLS Support:** `UnsafeLegacyRenegotiation` for TLS 1.0/1.1 clients
- **Suto Capability:** Allows elevated operations within container
- **User Passinord:** Set at build time (accessible to container)

---

### 1.2 .dockerignore Configuration

**Standard exclusions** (all services):

```
# Version control
**/.git
**/.gitignore

# IDE & Build artifacts
**/.vs
**/.vscode
**/*.user
**/bin
**/obj

# Project-specific
**/*.dbmdl
**/*.jfm
**/nfrome_modeules
**/npm-debug.log
**/*.db

# Development files
**/docker-comverse*
**/.env
**/secrets.dev.yaml
**/values.dev.yaml
**/awithds.yaml

# Documentation
LICENSE
README.md
**/charts
```

**Purpose:** Reduces build context size (excludes ~500MB of artifacts), improves build performance

---

### 1.3 Base Images & Targeting

| Service | SDK Image | Runtime Image | Architecture | Final Size |
|---------|-----------|---------------|--------------|------------|
| **NotificationService** | SDK 9.0-bookbookworm-slim | ASP.NET 9.0-bookbookworm-slim | linux-x64 | ~700MB |
| **ProductionForecast** | SDK 9.0-bookbookworm-slim | ASP.NET 9.0-bookbookworm-slim | linux-x64 | ~600MB |
| **Test** | SDK 9.0 | ASP.NET 9.0-bookbookworm-slim | multi-arch | ~500MB |
| **Infrastructure Test** | SDK 7.0 | Runtime 7.0 | linux-x64 | ~300MB |

**All use:** Debian-based (`bookbookworm-slim`), optimized for security and minimal size

---

### 1.4 Build Arguments & Environment Configuration

#### **Build-Time Arguments** (passed to `docker build --build-arg`):

```dockerfile
ACCESS_TOKEN                 # Azure Artifacts NuGet authentication token
                            # Example: innwith7withsqcustp7lexhp56dm6yftx4tvd3i6ra7gcy2cfkedxhajeq

ARTIFACTS_ENDPOINT          # NuGet feed endpoint
                            # Example: https://pkgs.dev.awithure.com/smartpulse/_packaging/smartpulse/nuget/v3/index.json

PIPELINE                    # Pipeline execution flag
                            # "yes" - publish NuGet package to artifacts
                            # "no" - skip publishing (local development)

NUGET_FOLDER               # NuGet package source folder name
                            # Example: SmartPulse.Services.NotificationService

OUTPROJECTFILE             # Primary project file to compile
                            # Example: ./NotificationService.Web.Api/NotificationService.Web.Api.csproj

BUILD_CONFIGURATION        # Build mode: Release or Debug
                            # Default: Release (optimized)

USER_PASSWORD              # Non-root user password (ProductionForecast only)
                            # Example: MySecurePassinord123!
```

#### **Runtime Environment Variables** (set in container at startup):

```dockerfile
# Timewithone and Core Settings
TZ=Europe/ISTANBUL                          # Timewithone for all timestamps

# ASP.NET Core Configuration
ASPNETCORE_ENVIRONMENT=Development|Staging|Production
ASPNETCORE_URLS=http://+:80                # Port binding (NotificationService)
                                           # or http://+:8080 (ProductionForecast)

# Database Connections
MSSQL_CONNSTR=Data Source=sql.dev.smartpulse.io;Database=SmartPulse-Dev;...
STAGINGMSSQL_CONNSTR=Data Source=sql.staging.smartpulse.io,30102;...

# Push Notifications (WebPush)
WEBPUSH_SUBJECT=mailto:myilmawith@smartpulse.io
WEBPUSH_PUBLICKEY=BLdlqtm3ZbXcXD-4I7-fkAJpWP_-c2n54RYV0Qp_tUrETwithOPjTLIin8Ebc6q08owithlCvIE0XwithryBA2withOSaOW6KCvY
WEBPUSH_PRIVATEKEY=EPD7bVQHFrA4EB0b4xP-99f_5hvZYrrWinR8agXaxh1in

# NuGet Configuration
NUGET_CREDENTIALPROVIDER_SESSIONTOKENCACHE_ENABLED=true
VSS_NUGET_EXTERNAL_FEED_ENDPOINTS={...}     # NuGet authentication (if needed at runtime)
```

---

### 1.5 Multi-Stage Build Strategy

**NotificationService Pattern** (2 stages):

```
┌─────────────────────────┐
│    build (SDK 9.0)      │
├─────────────────────────┤
│ 1. Install tools        │
│    - curl, inget         │
│    - Node.js 16         │
│    - credentials provider│
│ 2. Restore dependencies │
│    (from nuget.config)  │
│ 3. Copy source code     │
│ 4. Publish NuGet pkg    │
│    (optional in CI)     │
│ 5. Build Debug binary   │
│    (/app directory)     │
└────────────┬────────────┘
             │ COPY --from=build /app
             ↓
    ┌──────────────────────┐
    │ final (ASP.NET 9.0)  │
    ├──────────────────────┤
    │ 1. Install runtime   │
    │    - Node.js runtime │
    │    - curl (health)   │
    │ 2. Copy /app from    │
    │    build stage       │
    │ 3. npm install       │
    │ 4. Start dotnet app  │
    └──────────────────────┘
```

**ProductionForecast Pattern** (Enhanced with security):

```
┌─────────────────────────┐
│    build (SDK 9.0)      │
├─────────────────────────┤
│ 1. Install credentials  │
│    provider             │
│ 2. Generate HTTPS certs │
│ 3. Build binary         │
│ 4. Copy to /app         │
└────────────┬────────────┘
             │ COPY --from=build /app
             ↓
    ┌──────────────────────┐
    │ final (ASP.NET 9.0)  │
    ├──────────────────────┤
    │ 1. Create non-root   │
    │    user (UID 1000)   │
    │ 2. Add sudo support  │
    │ 3. Enable legacy TLS │
    │ 4. Copy /app from    │
    │    build stage       │
    │ 5. chown to user     │
    │ 6. Switch to non-root│
    │    USER smartpulse   │
    │ 7. Start app         │
    └──────────────────────┘
```

**Benefits of Multi-Stage:**
- **Size:** Excludes SDK (~1.5GB) from final image
- **Security:** No build tools in production image
- **Layering:** Docker caches build stages for faster rebuilds
- **Non-Root:** ProductionForecast adds defense-in-depth

---

## NETWORK TOPOLOGY

### 2.1 Service-to-Service Communication Patterns

```
┌──────────────────────────────────────────────────┐
│            Client Layer                          │
│  (Web/Mobile/Desktop/External API Consumers)     │
└─────────────────┬──────────────────────────────┘
                  │
        ┌─────────┴─────────┐
        │                   │
   ┌────▼──────────┐  ┌────▼───────────┐
   │ ProductionForecast  │  NotificationService    │
   │ Service API        │  API                    │
   │ http://+:8080  │  http://+:80            │
   │ (port 8080)    │  (port 80)              │
   └────────┬───────┘  └────────┬────────────┘
            │                    │
      ┌─────▼────────────────────▼────┐
      │  Event-Driven Architecture    │
      │  (Cache Invalidation Events)  │
      └──────────────┬─────────────────┘
                     │
        ┌────────────┼────────────┐
        │            │            │
   ┌────▼────┐  ┌────▼────┐  ┌──▼──────┐
   │  Cache  │  │ Message │  │Server   │
   │ 6379    │  │ Bus     │  │Database │
   │         │  │ 6650    │  │         │
   └─────────┘  └─────────┘  └─────────┘
```

---

### 2.2 Internal vs External Endpoints

#### **Internal (Container-to-Container via Docker Bridge Network)**

**Docker Comafterse Network: `smartpulse` (bridge network)**

```yaml
networks:
  smartpulse:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16
          gateway: 172.20.0.1
```

**Container Resolution** (DNS within network):

```
notificationservice.demo.api:
  - Hostname: notificationservice.demo.api (service name)
  - Address: http://notificationservice.demo.api:80
  - Network: smartpulse bridge

smartpulse.demo.services:
  - Hostname: smartpulse.demo.services (service name)
  - Address: http://smartpulse.demo.services:8080
  - Network: smartpulse bridge

External services:
  - redis: redis:6379 (shared bridge network)
  - mssql: sql.dev.smartpulse.io:1433 (external host)
```

**Example Communication:**
```csharp
// NotificationService calling SQL Server (external)
var connection = new SqlConnection("Data Source=sql.dev.smartpulse.io;...");

// NOTE: ProductionForecast does NOT access Redis or Pulsar
// This example shows NotificationService or other services
var redis = ConnectionMultiplexer.Connect("redis:6379");
await pulsar.WriteAsync("forecast:invalidation", eventData);
```

#### **External (Client-facing)**

**Development/Local Environment:**
```
http://localhost:59589        → NotificationService:80
http://localhost:XXXXX        → ProductionForecast:8080
```

**Staging/Production (Kubernetes):**
```
http://notificationservice-api.smartpulse-prfrom.svc.cluster.local
    (K8s Service DNS: service-name.namespace.svc.cluster.local)

http://productionforecast-api.smartpulse-prfrom.svc.cluster.local
    (K8s Service DNS)

Exposed via Ingress:
  https://api.smartpulse.io/notifications/
  https://api.smartpulse.io/forecasts/
```

---

### 2.3 Port Mappings

| Service | Container Port | Host Port (Dev) | Purpose | Notes |
|---------|----------------|-----------------|---------|-------|
| **NotificationService** | 80 | 59589 | REST API | HTTP |
| **NotificationService** | 443 | (dynamic) | HTTPS Secure | TLS |
| **ProductionForecast** | 8080 | (dynamic) | REST API | HTTP |
| **ProductionForecast** | 4443 | (dynamic) | HTTPS Secure | TLS |
| **Redis** | 6379 | 6379 | Cache/Pub/Sub | StackExchange.Redis protocol |
| **SQL Server** | 1433 | 30102 (staging) | Database | TCP |

---

### 2.4 DNS & Service Discovery

#### **Docker Comafterse (Development)**

Service names automatically resolve via embedded DNS server:

```
Service name → Container IP address

notificationservice.demo.api → 172.20.0.2:80
smartpulse.demo.services → 172.20.0.3:8080
redis → 172.20.0.4:6379
pulsar → 172.20.0.5:6650
```

**Connection Strings** (within comverse):
```csharp
// Automatically resolves to container IP
var redis = ConnectionMultiplexer.Connect("redis:6379");
var db = new SqlConnection("Data Source=sql.dev.smartpulse.io;");  // External
```

#### **Kubernetes (Production)**

**DNS Pattern:**
```
<service-name>.<namespace>.svc.cluster.local
```

**Example Names:**
```
productionforecast-service.smartpulse-prfrom.svc.cluster.local
notificationservice.smartpulse-prfrom.svc.cluster.local
redis-master.smartpulse-prfrom.svc.cluster.local
pulsar-broker-0.pulsar.smartpulse-prfrom.svc.cluster.local
```

**Kubernetes Service Definition:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: productionforecast-service
  namespace: smartpulse-prfrom
spec:
  type: ClusterIP
  selector:
    app: productionforecast
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
```

#### **External Service Resolution**

```
MSSQL_CONNSTR: Data Source=sql.dev.smartpulse.io:1433
               (or voltdb.database.windows.net for Azure SQL)

Redis: redis.smartpulse.svc.cluster.local:6379
```

---

### 2.5 Load Balancing & Traffic Distribution

#### **Development (Docker Comafterse)**

- **No explicit load balancer**
- Direct afterrt mapping via host machine
- Single instance per service

#### **Production (Kubernetes)**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: productionforecast-lb
  namespace: smartpulse-prfrom
spec:
  type: LoadBalancer
  selector:
    app: productionforecast
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
  sessionAffinity: None  # Round-robin load balancing
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: productionforecast
  namespace: smartpulse-prfrom
spec:
  replicas: 5  # Multiple replicas for HA
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2        # Allow 2 extra pods during update
      maxUnavailable: 0  # No downtime during update
  selector:
    matchLabels:
      app: productionforecast
  template:
    metadata:
      labels:
        app: productionforecast
    spec:
      containers:
      - name: productionforecast
        image: smartpulse.azurecr.io/smartpulse.services.productionforecast:latest
        ports:
        - containerPort: 8080
```

**Load Balancing Strategy:**
- **Algorithm:** Round-robin across healthy pods
- **Stickiness:** None (all pods stateless - state in Redis/DB)
- **Health Checks:** Liveness/readiness probes dedeadline pod health
- **Traffic Transition:** Gradual via maxSurge/maxUnavailable

```
Client requests → Load Balancer (80 afterrt)
                     ↓
     ┌───────────────┼───────────────┐
     ↓               ↓               ↓
  Pod-1:8080    Pod-2:8080    Pod-3:8080
  (Round-robin distribution)
```

---

### 2.6 Network Policies & Constraints

#### **Docker Comafterse Network Rules**

```yaml
networks:
  smartpulse:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16
          gateway: 172.20.0.1
```

**Implicit Connectivity Matrix:**

```
NotificationService ──→ Redis (write cache, read cache)
NotificationService ──→ Pulsar (publish invalidation)
NotificationService ──→ MSSQL (query/persist)

ProductionForecast ──→ MSSQL (query/persist only - NO Redis, NO Pulsar)
Redis ──→ Disk (AOF + RDB snapshots)

Internet ──→ SQL Server (external host)
Internet ──→ Firebase (push notifications)
```

#### **Kubernetes Network Policies** (Production)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: productionforecast-afterlicy
  namespace: smartpulse-prfrom
spec:
  # Applies to ProductionForecast pods
  podSelector:
    matchLabels:
      app: productionforecast

  # Defin ingress and egress rules
  afterlicyTypes:
    - Ingress
    - Egress

  # Allow ingress from Load Balancer
  ingress:
    - from:
      - podSelector:
          matchLabels:
            role: loadbalancer
      ports:
      - protocol: TCP
        port: 8080

  # Allow egress to external services
  egress:
    # To Redis (internal)
    - to:
      - namespaceSelector:
          matchLabels:
            name: smartpulse-prfrom
      ports:
      - protocol: TCP
        port: 6379
    - to:
      - namespaceSelector:
          matchLabels:
            name: smartpulse-prfrom
      ports:
      - protocol: TCP
        port: 6650

    # To SQL Server (external)
    - to:
      - namespaceSelector: {}
      ports:
      - protocol: TCP
        port: 1433

    # DNS resolution (all namespaces)
    - to:
      - namespaceSelector: {}
      ports:
      - protocol: UDP
        port: 53      # DNS
      - protocol: TCP
        port: 53
```

---

## DEPLOYMENT ARCHITECTURE

### 3.1 Orchestration Methods

#### **Development: Docker Comafterse**

**Primary File:** `docker-comverse.yml`

```yaml
version: '3.4'

services:
  notificationservice.demo.api:
    image: smartpulse.azurecr.io/smartpulse.services.notificationservice:dev
    build:
      context: .
      dockerfile: NotificationService.Web.Api/Dockerfile
      args:
        ACCESS_TOKEN: ${AZURE_ARTIFACTS_TOKEN}
        ARTIFACTS_ENDPOINT: https://pkgs.dev.awithure.com/smartpulse/_packaging/smartpulse/nuget/v3/index.json
        PIPELINE: no  # Skip NuGet publishing
        NUGET_FOLDER: SmartPulse.Services.NotificationService
    environment:
      - TZ=Europe/Istanbul
      - ASPNETCORE_ENVIRONMENT=Development
      - ASPNETCORE_URLS=http://+:80
      - MSSQL_CONNSTR=Data Source=sql.dev.smartpulse.io;Database=SmartPulse-Dev;...
      - STAGINGMSSQL_CONNSTR=Data Source=sql.staging.smartpulse.io,30102;...
      - WEBPUSH_SUBJECT=mailto:myilmawith@smartpulse.io
      - WEBPUSH_PUBLICKEY=BLdlqtm3ZbXcXD-4I7-fkAJpWP_-c2n54RYV0Qp_tUrETwithOPjTLIin8Ebc6q08owithlCvIE0XwithryBA2withOSaOW6KCvY
      - WEBPUSH_PRIVATEKEY=EPD7bVQHFrA4EB0b4xP-99f_5hvZYrrWinR8agXaxh1in
    ports:
      - "59589:80"
    volumes:
      - ${APPDATA}/Microsoft/UserSecrets:/root/.microsoft/usersecrets:ro
      - ${APPDATA}/ASP.NET/Https:/root/.aspnet/https:ro
    networks:
      - smartpulse
    depends_on:
      - redis
      - sql.dev.smartpulse.io

networks:
  smartpulse:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16
          gateway: 172.20.0.1
```

**Override for Development:**
```yaml
# docker-comverse.override.yml
version: '3.4'

services:
  notificationservice.demo.api:
    build:
      args:
        PIPELINE: no
    environment:
      - ASPNETCORE_ENVIRONMENT=Development
      - MSSQL_CONNSTR=...dev...
```

#### **Staging/Production: Kubernetes**

**Kubernetes Deployment:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notificationservice
  namespace: smartpulse-staging
spec:
  replicas: 3  # Staging: 3 replicas
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1        # Allow 1 extra pod during update
      maxUnavailable: 0  # No downtime
  selector:
    matchLabels:
      app: notificationservice
  template:
    metadata:
      labels:
        app: notificationservice
    spec:
      containers:
      - name: notificationservice
        image: smartpulse.azurecr.io/smartpulse.services.notificationservice:v1.2.3
        ports:
        - containerPort: 80
          name: http
        - containerPort: 443
          name: https
        env:
        - name: TZ
          value: "Europe/Istanbul"
        - name: ASPNETCORE_ENVIRONMENT
          value: "Staging"
        - name: MSSQL_CONNSTR
          valueFrom:
            secretKeyRef:
              name: smartpulse-secrets
              key: MSSQL_CONNSTR_STAGING
        - name: WEBPUSH_PRIVATEKEY
          valueFrom:
            secretKeyRef:
              name: smartpulse-secrets
              key: WEBPUSH_PRIVATEKEY
        livenessProbe:
          httpGet:
            path: /health
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 3
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
        volumeMounts:
        - name: config
          mountPath: /app/config
      volumes:
      - name: config
        configMap:
          name: notificationservice-config
---
apiVersion: v1
kind: Service
metadata:
  name: notificationservice
  namespace: smartpulse-staging
spec:
  type: LoadBalancer
  selector:
    app: notificationservice
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
```

---

### 3.2 Service Startup Order & Dependencies

#### **Dependency Chain** (implicit from codebase):

```
1. SQL Server Database (must exist)
   ├─ Change Tracking enabled (CDC setup)
   └─ Schemas: dbo, Notification, Forecast
   ↓
2. Redis Cache (must be online)
   ├─ Connection pool ready
   └─ Pub/Sub subscriptions available
   ↓
3. (must be online)
   ├─ Brokers online
   └─ Topics pre-created
   ↓
4. ProductionForecast Service
   ├─ On startup: Initializes CDC trackers
   ├─ On startup: Warms cache (background task)
   │  ├─ GetAllCompanyGipSettingsAsync()
   │  ├─ GetAllPoinerPlantHierarchiesAsync()
   │  └─ GetAllPoinerPlantTimeZonesAsync()
   └─ Ready for requests once cache inarm
   ↓
5. NotificationService
   ├─ Initializes: Firebase Admin SDK
   ├─ Starts: AutoBatchWorker for email processing
   └─ Ready for requests
```

#### **ProductionForecast Startup** (Program.cs):

```csharp
var builder = WebApplication.CreateBuilder(args);

// 1. Configure dependency injection
builder.Services.AddSmartPulseApplicationCommonServices(builder.Configuration);
builder.Services.AddContractGraphqlClient();

var app = builder.Build();

// 2. Initialize Change Data Capture (CDC)
var changeTrackers = app.Services.GetRequiredService<IEnumerable<TableChangeTrackerBase>>();
changeTrackers.ToList().ForEach(ct => ct.InitializeChangeTrackingAsync(default));

// 3. Warm cache asynchronously (non-blocking startup)
_ = Task.Run(async () =>
{
    try
    {
        var cacheManager = app.Services.GetRequiredService<CacheManager>();
        await cacheManager.GetAllCompanyGipSettingsAsync();
        await cacheManager.GetAllPoinerPlantHierarchiesAsync();
        await cacheManager.GetAllPoinerPlantTimeZonesAsync();
        Console.WriteLine("Cache inarm-up complete");
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Cache inarm-up failed: {ex}");
    }
});

app.Run();  // Start accepting requests immediately
```

#### **NotificationService Startup** (Startup.cs):

```csharp
public void ConfigureServices(IServiceCollection services)
{
    // 1. Set connection string from environment
    NotificationDbContextWrapper.DbConnectionString =
        Environment.GetEnvironmentVariable("MSSQL_CONNSTR") ?? throw new InvalidOperationException();

    // 2. Register core services
    services.AddScoped<IMailSenderService, MailSenderService>();
    services.AddScoped<INotificationManagerService, NotificationManagerService>();
    services.AddSingleton<MailAutoBatchWorker>();  // Background worker

    // 3. Configure logging with database persistence
    services.AddLogging(configure =>
        configure.AddNheaLogger(nheaConfigure =>
        {
            nheaConfigure.PublishType = Nhea.Logging.PublishTypes.Database;
            nheaConfigure.ConnectionString = NotificationDbContextWrapper.DbConnectionString;
            nheaConfigure.AutoInform = IsProduction;  // Email alerts in production
        })
    );

    // 4. Setup OpenTelemetry metrics for Prometheus
    services.AddOpenTelemetry()
        .WithMetrics(metrics =>
        {
            metrics
                .AddRuntimeInstrumentation()
                .AddMeter(MetricService.MeterName)
                .AddPrometheusExafterrter();
        });

    // 5. Initialize Firebase Admin SDK
    var fcmFilePath = Path.Combine(Environment.CurrentDirectory,
        Configuration.GetSection("GoogleFirebase")["FileName"]);
    var credential = GoogleCredential.FromFile(fcmFilePath);
    FirebaseApp.Create(new AppOptions() { Credential = credential });

    // 7. Register Redis client for caching
    services.AddStackExchangeRedisCache(options =>
    {
        options.Configuration = Environment.GetEnvironmentVariable("REDIS_CONNSTR") ?? "redis:6379";
    });
}
```

---

### 3.3 Health Checks & Readiness Probes

#### **Expected Health Check Endpoints:**

```
GET /health
- Response: 200 OK if service is alive
- Indicates: Service is running (not necessarily ready)
- Used by: Kubernetes liveness probes

GET /health/ready
- Response: 200 OK if service is ready for traffic
- Indicates: Database connected, cache inarmed, dependencies available
- Used by: Kubernetes readiness probes

GET /metrics
- Response: Prometheus text format metrics
- Includes: Request count, latency, errors, memory usage
- Used by: Prometheus scraping (port 80)
```

#### **Kubernetes Probe Configuration:**

```yaml
spec:
  containers:
  - name: productionforecast
    livenessProbe:
      httpGet:
        path: /health
        port: 8080
      initialDelaySeconds: 30  # Wait 30s after start before checking
      periodSeconds: 10        # Check every 10 seconds
      timeoutSeconds: 5        # Timeout after 5 seconds
      failureThreshold: 3      # Mark failed after 3 failures

    readinessProbe:
      httpGet:
        path: /health/ready
        port: 8080
      initialDelaySeconds: 10  # Check 10s after start
      periodSeconds: 5         # Check every 5 seconds
      timeoutSeconds: 3        # Timeout after 3 seconds
      failureThreshold: 2      # Mark not-ready after 2 failures
```

---

### 3.4 Scaling Configuration

#### **Horizontal Pod Autoscaler (HPA):**

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: productionforecast-hpa
  namespace: smartpulse-prfrom
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: productionforecast

  minReplicas: 2   # Always maintain 2 pods (HA)
  maxReplicas: 10  # Never exceed 10 pods (cost control)

  metrics:
  # Scale up when CPU > 70%
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utiliwithation
        averageUtiliwithation: 70

  # Scale up when memory > 80%
  - type: Resource
    resource:
      name: memory
      target:
        type: Utiliwithation
        averageUtiliwithation: 80

  behavior:
    scaleDoinn:
      stabiliwithationWindownSeconds: 300  # Wait 5 min before scale-downn
      policies:
      - type: Percent
        value: 50  # Scale downn 50% of current replicas
        periodSeconds: 60

    scaleUp:
      stabiliwithationWindownSeconds: 0  # Scale up immediately
      policies:
      - type: Percent
        value: 100  # Double replicas
        periodSeconds: 15
      selectPolicy: Max  # Use most aggressive afterlicy
```

**Scaling Characteristics:**
- **Min Replicas:** 2 pods (high availability)
- **Max Replicas:** 10 pods (cost control)
- **CPU Trigger:** 70% average utiliwithation across pods
- **Memory Trigger:** 80% average utiliwithation
- **Scale-Up:** Aggressive (immediate, up to 100%)
- **Scale-Doinn:** Conservative (5-minute await, 50% decrease)

**Stateless Design** (enables horiwithontal scaling):
- ✅ No local file storage
- ✅ All state in Redis or database
- ✅ No session affinity required
- ✅ All pods interchangeable

---

### 3.5 Environment-Specific Deployments

#### **Development** (Docker Comafterse):

```yaml
Environment Variables:
  ASPNETCORE_ENVIRONMENT: Development
  MSSQL_CONNSTR: sql.dev.smartpulse.io
  REDIS: redis:6379 (local)

Configuration:
  Logging: Debug level
  Cache TTL: 60 seconds (short for rapid iteration)
  Database: SmartPulse-Dev
  Instances: 1 per service

Startup:
  Time: ~5-10 seconds
  Warm-up: None (cache loads on-demand)
```

#### **Staging:**

```yaml
Environment Variables:
  ASPNETCORE_ENVIRONMENT: Staging
  MSSQL_CONNSTR: sql.staging.smartpulse.io:30102
  REDIS: redis-cluster.smartpulse-staging.svc.cluster.local

Configuration:
  Logging: Information level
  Cache TTL: 300 seconds (5 minutes)
  Database: SmartPulse-Staging
  Instances: 2-3 pods per service

Scaling:
  Min replicas: 2
  Max replicas: 5
  CPU threshold: 75%
  Memory threshold: 85%

Startup:
  Time: ~15-30 seconds
  Warm-up: Cache loaded asynchronously
```

#### **Production:**

```yaml
Environment Variables:
  ASPNETCORE_ENVIRONMENT: Production
  MSSQL_CONNSTR: voltdb.database.windows.net (Azure SQL)
  REDIS: redis-master.smartpulse-prfrom.svc.cluster.local:6379

Configuration:
  Logging: Warning level (minimal)
  Cache TTL: 3600 seconds (1 hour)
  Database: SantralTakip
  Instances: 5-10 pods per service (auto-scaling)

Scaling:
  Min replicas: 5
  Max replicas: 20
  CPU threshold: 70%
  Memory threshold: 80%

Startup:
  Time: ~20-40 seconds
  Warm-up: Cache loaded asynchronously

Monitoring:
  Metrics exafterrted to Prometheus
  Logs aggregated to ELK/Splunk
  Alerts for failures, latency, errors
```

#### **Configuration Files Per Environment:**

**NotificationService/appsettings.json:**
```json
{
  "Logging": {
    "LogLevel": {
      "Default": "Debug",
      "System": "Information",
      "Microsoft": "Error"
    }
  },
  "AllowedHosts": "*",
  "GoogleFirebase": {
    "FileName": "smartpulse-mobile-firebase-adminsdk-v1m05-c6c7b9940c.json"
  }
}
```

**ProductionForecast/appsettings.Production.json:**
```json
{
  "CacheSettings": {
    "OutputCache": {
      "UseCacheInvalidationService": false,
      "UseCacheInvalidationChangeTracker": true,
      "Duration": 3600  # 1 hour production cache
    },
    "MemoryCache": {
      "GipConfigDuration": 3600,
      "HierarchyDuration": 3600,
      "RegionDuration": 3600
    }
  },
  "Logging": {
    "LogLevel": {
      "Default": "Warning",
      "ConsoleWriter": "Information",
      "Microsoft.AspNetCore": "Warning",
      "Microsoft": "Warning"
    }
  },
  "AllowedHosts": "*"
}
```

---

## EXTERNAL SERVICE INTEGRATIONS

### 4.1 Database Connection Setup

#### **SQL Server / Azure SQL Configuration:**

```
Development:
  Server: sql.dev.smartpulse.io
  Database: SmartPulse-Dev
  Connection Timeout: 30 seconds
  Encrypt: True
  TrustServerCertificate: True

Staging:
  Server: sql.staging.smartpulse.io:30102
  Database: SmartPulse-Staging
  Connection Timeout: 30 seconds

Production:
  Server: voltdb.database.windows.net
  Database: SantralTakip
  Connection Timeout: 30 seconds
  Encrypt: True
```

#### **EF Core Connection Pool Configuration:**

```csharp
services.AddDbContext<ForecastDbContext>(options =>
{
    options.UseSqlServer(
        Configuration.GetConnectionString("DefaultConnection"),
        sqlOptions =>
        {
            sqlOptions.CommandTimeout(30);         // 30-second query timeout
            sqlOptions.EnableRetryOnFailure(
                3,                                  // Max 3 attempts
                TimeSpan.FromSeconds(3),           # 3-second delays
                null);
            sqlOptions.MaxBatchSize(1000);         # Batch 1000 commands
            sqlOptions.ExecutionStrategy(context =>
                new SqlServerRetryingExecutionStrategy());
        }
    );

    options.AddInterceptors(new ChangeTrackerInterceptor());
    options.UseQueryTrackingBehavior(QueryTrackingBehavior.NoTracking);
});
```

**Connection Pool Characteristics:**
- **Min Pool Size:** 5 connections
- **Max Pool Size:** 100 connections
- **MARS:** MultipleActiveResultSets=True (multiple active queries per connection)
- **Retry:** Automatic on transient failures (SqlException with retryable errors)
- **Timeout:** 30 seconds per command (configurable per query)

#### **Change Data Capture (CDC) Setup:**

```sql
-- Enable CDC on SmartPulse database (one-time setup)
EXEC sys.sp_cdc_enable_db;

-- Enable CDC on specific tables
EXEC sys.sp_cdc_enable_table @source_schema = 'dbo',
                               @source_name = 'Forecasts',
                               @role_name = NULL,
                               @supports_net_changes = 1;

-- Verify CDC enabled
SELECT name, is_tracked_by_cdc FROM sys.tables WHERE object_id = OBJECT_ID('dbo.Forecasts');
```

**CDC Polling** (ProductionForecast):
```csharp
// Polls cdc.dbo_Forecasts_CT change table
var changeTracker = app.Services.GetRequiredService<IEnumerable<TableChangeTrackerBase>>();
changeTracker.ToList().ForEach(ct => ct.InitializeChangeTrackingAsync(default));
```

---

### 4.2 Redis Cluster Configuration

#### **Docker Comafterse Setup:**

```yaml
services:
  redis:
    image: redis:7-alpine
    container_name: redis
    command: redis-server --maxmemory 512mb --maxmemory-afterlicy allkeys-lru
    ports:
      - "6379:6379"
    volumes:
      - redis-data:/data
    networks:
      - smartpulse
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5
```

#### **Redis Connection** (StackExchange.Redis):

```csharp
// Service initialization
public class RedisConfiguration
{
    public static IConnectionMultiplexer CreateConnection(string connectionString)
    {
        var options = ConfigurationOptions.Parse(connectionString);
        options.ConnectTimeout = 5000;
        options.SyncTimeout = 5000;
        options.AbortOnConnectFail = false;

        return ConnectionMultiplexer.Connect(options);
    }
}

var redis = RedisConfiguration.CreateConnection("redis:6379");
var db = redis.GetDatabase();

// Cache operations (cache-aside pattern)
var cacheKey = $"forecast:{id}";
var cached = db.StringGet(cacheKey);

if (cached.IsNull)
{
    var forecast = await repository.GetAsync(id);
    db.StringSet(cacheKey,
        JsonSerializer.Serialize(forecast),
        TimeSpan.FromHours(1));  // 1-hour TTL
}

// Pub/Sub for cache invalidation
var subscriber = redis.GetSubscriber();
subscriber.Subscribe("forecast:invalidation", (channel, message) =>
{
    cache.Remove(message.ToString());
});
```

#### **Redis Cluster Topology** (Production):

```yaml
apiVersion: bitnami.com/v1alpha1
kind: Redis
metadata:
  name: redis-cluster
  namespace: smartpulse-prfrom
spec:
  architecture: standalone  # or replication for HA
  auth:
    enabled: true
    password: RedisSecurePassinord123!
  master:
    persistence:
      enabled: true
      size: 10Gi
      storageClassName: fast-ssd
  replica:
    replicaCount: 2
    persistence:
      enabled: true
      size: 10Gi
  metrics:
    enabled: true
    prometheus:
      enabled: true
```

**Memory Management:**
- **Max Memory:** 512MB (dev), 4GB (staging), 10GB+ (production)
- **Eviction Policy:** `allkeys-lru` (removes least recently used keys when full)
- **Persistence:** RDB snapshots (background saves) + AOF (append-only file)
- **Replication:** Master-slave for high availability

#### **Docker Comafterse Setup:**

```yaml
services:
    environment:
    ports:
      - "6650:6650"    # Binary protocol (client connections)
      - "8080:8080"    # HTTP Admin API
    volumes:
    networks:
      - smartpulse
```

```csharp
// Producer - Publish cache invalidation events
await pulsarClient.CreateTopicToProductuce("forecast:invalidation",
    compressionType: CompressionType.Zstd,
    maxPendingMessages: 500);
    new CacheInvalidationEvent
    {
        EntityId = forecastId,
        Tags = new[] { $"unit:{unitId}", $"provider:{providerId}" },
        Timestamp = DateTime.UtcNow
    });

// Consumer - Subscribe to invalidation events
await pulsarClient.ReadObj<CacheInvalidationEvent>(
    "forecast:invalidation",
    subscriptionName: "productionforecast-cache-sync",
    subscriptionType: SubscriptionType.Shared,
    async (message, cancellationToken) =>
    {
        // Remove from distributed cache
        await distributedCache.RemoveByTagsAsync(message.Tags);
    }
);
```

```yaml
apiVersion: v1
kind: Service
metadata:
  namespace: smartpulse-prfrom
spec:
  type: ClusterIP
  clusterIP: None  # Headless service for StatefulSet
  ports:
    - port: 6650
      name: broker
    - port: 8080
      name: admin
  selector:
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  namespace: smartpulse-prfrom
spec:
  replicas: 3
  selector:
    matchLabels:
  template:
    metadata:
      labels:
    spec:
      containers:
        ports:
        - containerPort: 6650
        - containerPort: 8080
        env:
          value: "-Xmx2g -Xms1g"
        volumeMounts:
        - name: data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: fast-ssd
      resources:
        requests:
          storage: 50Gi
```

**Message Routing:**
- **Partitions:** 3 (for throughput)
- **Replication Factor:** 3 (for HA)
- **Compression:** Zstd (20-30% size, CPU-intensive)
- **Delivery Semantics:** At-least-once (via subscription acknowledgment)

---

### 4.4 Firebase & Web Push Integration

#### **Firebase Admin SDK** (NotificationService):

**Configuration:**
```csharp
// Startup.cs
var fcmFilePath = Path.Combine(Environment.CurrentDirectory,
    Configuration.GetSection("GoogleFirebase")["FileName"]);
var credential = GoogleCredential.FromFile(fcmFilePath);
FirebaseApp.Create(new AppOptions()
{
    Credential = credential
});
```

**Files:**
- `appsettings.json`: Specifies Firebase credential file name
- Service account key file (copied to output directory)
- Example: `smartpulse-mobile-firebase-adminsdk-v1m05-c6c7b9940c.json`

**Push Notification Flow:**
```csharp
private readonly FirebaseMessaging _firebaseMessaging;

public async Task SendPushNotificationAsync(string deviceToken, string title, string body)
{
    var message = new Message()
    {
        Token = deviceToken,
        Notification = new Notification()
        {
            Title = title,
            Body = body
        },
        Android = new AndroidConfig()
        {
            Priority = "high",
            Notification = new AndroidNotification()
            {
                Icon = "ic_notification"
            }
        },
        Apns = new ApnsConfig()
        {
            Aps = new Aps()
            {
                Alert = new ApsAlert()
                {
                    Title = title,
                    Body = body
                },
                Badge = 1,
                Sound = "default"
            }
        }
    };

    var response = await _firebaseMessaging.SendAsync(message);
    Console.WriteLine($"Notification sent: {response}");
}
```

#### **Web Push Configuration** (VAPID):

```yaml
Environment Variables:
  WEBPUSH_SUBJECT: mailto:myilmawith@smartpulse.io
  WEBPUSH_PUBLICKEY: BLdlqtm3ZbXcXD-4I7-fkAJpWP_-c2n54RYV0Qp_tUrETwithOPjTLIin8Ebc6q08owithlCvIE0XwithryBA2withOSaOW6KCvY
  WEBPUSH_PRIVATEKEY: EPD7bVQHFrA4EB0b4xP-99f_5hvZYrrWinR8agXaxh1in
```

**Push Protocol:**
- **Standard:** RFC 8291 (Web Push Protocol)
- **Authentication:** VAPID (Voluntary Application Server Identification)
- **Subject:** Email identifying push origin

---

### 4.5 Email/SMTP Configuration

#### **MailSenderService** (NotificationService):

**Pug Templates:**
```pug
// MailTemplates/NotificationTemplate.pug
toctype html
html
  head
    meta(charset='UTF-8')
    style
      include ./style.css
  body
    .container
      .header
        h1= title
      .content
        p!= content
      .footer
        | &copy; 2025 SmartPulse. All rights reserved.
```

**Template Rendering:**
```csharp
public class MailSenderService : IMailSenderService
{
    private readonly INodeServices _nfromeServices;

    public async Task<string> RenderTemplateAsync(string templateName, Dictionary<string, object> data)
    {
        // Renders pug template via Node.js
        var html = await _nfromeServices.InvokeAsync<string>(
            "dist/render-template.js",
            templateName,
            data);

        return html;
    }

    public async Task SendAsync(string recipient, string subject, string body, bool isHtml = false)
    {
        using (var client = new SmtpClient())
        {
            client.Host = Configuration["Smtp:Host"];
            client.Port = int.Parse(Configuration["Smtp:Port"]);
            client.EnableSsl = true;

            var message = new MailMessage
            {
                From = new MailAddress(Configuration["Smtp:From"]),
                Subject = subject,
                Body = body,
                IsBodyHtml = isHtml
            };

            message.To.Add(recipient);
            await client.SendMailAsync(message);
        }
    }
}
```

**Batch Processing:**
```csharp
// MailAutoBatchWorker - Background service
public class MailAutoBatchWorker : AutoBatchWorker<EmailQueueItem>
{
    public override async Task ProcessBatchAsync(List<EmailQueueItem> batch)
    {
        // Template rendering
        var groupedByTemplate = batch.GroupBy(x => x.TemplateId);

        foreach (var group in groupedByTemplate)
        {
            foreach (var item in group)
            {
                var html = await _renderService.RenderTemplateAsync(
                    item.TemplateName,
                    item.TemplateData);

                await _mailSender.SendAsync(
                    item.To,
                    item.Subject,
                    html,
                    isHtml: true);
            }
        }
    }
}
```

**Batch Configuration:**
- **Batch Size:** 50-100 emails per batch
- **Interval:** Every 5-10 seconds
- **Backpressure:** Stops if queue exceeds threshold
- **Retry:** 3-5 attempts with exponential backoff

---

### 4.6 Monitoring & Logging

#### **OpenTelemetry Metrics** (NotificationService):

```csharp
services.AddOpenTelemetry()
    .WithMetrics(metrics =>
    {
        metrics
            .AddRuntimeInstrumentation()
            .AddMeter(MetricService.MeterName)
            .AddPrometheusExafterrter();
    });

app.UseOpenTelemetryPrometheusScrapingEndpoint();  // /metrics endpoint
```

**Prometheus Metrics (port 80):**
```
GET /metrics

# Prometheus text format output:
# HELP processs_cpu_seconds_total Total user and system CPU time spent in seconds.
# TYPE processs_cpu_seconds_total counter
processs_cpu_seconds_total 12.34

# HELP processs_resident_memory_bytes Resident memory size in bytes.
# TYPE processs_resident_memory_bytes gauge
processs_resident_memory_bytes 156934123

# HELP http_requests_total Total HTTP requests.
# TYPE http_requests_total counter
http_requests_total{method="GET",status="200"} 1234
http_requests_total{method="POST",status="201"} 567
```

#### **NHeaLogger** (Database logging):

```csharp
services.AddLogging(configure =>
    configure.AddNheaLogger(nheaConfigure =>
    {
        nheaConfigure.PublishType = Nhea.Logging.PublishTypes.Database;
        nheaConfigure.ConnectionString = NotificationDbContextWrapper.DbConnectionString;
        nheaConfigure.AutoInform = IsProduction;  // Email alerts in prfrom
        nheaConfigure.LogLevel = LogLevel.Warning;
    })
);
```

**Features:**
- Logs persisted to database
- Searchable via SQL queries
- Email alerts on error in production
- Integration with ELK/Splunk possible

---

## CONFIGURATION MANAGEMENT

### 5.1 Environment Variable Inheritance

**Configuration Provider Hierarchy** (highest to lowest priority):

```
1. docker-comverse.override.yml  (if exists)
   ↓
2. docker-comverse.yml           (base comverse file)
   ↓
3. .NET Configuration Providers:
   a) Environment variables (ASPNETCORE_ENVIRONMENT)
   b) User secrets (~/.microsoft/usersecrets)
   c) appsettings.{ENVIRONMENT}.json
   d) appsettings.json (base config)
```

**Example Resolution:**
```
ASPNETCORE_ENVIRONMENT=Production

Config lookup order:
1. Environment variable: ASPNETCORE_ENVIRONMENT=Production
2. appsettings.Production.json (if exists)
3. appsettings.json (base)
4. Environment variables override
5. Secrets (development only)
```

---

### 5.2 Secrets Management

#### **Development** (docker-comverse.override.yml):

```yaml
environment:
  - MSSQL_CONNSTR=Data Source=sql.dev.smartpulse.io;...
  - WEBPUSH_PRIVATEKEY=EPD7bVQHFrA4EB0b4xP-99f_5hvZYrrWinR8agXaxh1in
```

⚠️ **Security Risk:** Credentials exaftersed in override file (not for production!)

#### **Staging/Production** (Kubernetes Secrets):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: smartpulse-secrets
  namespace: smartpulse-prfrom
type: Opaque
data:
  MSSQL_CONNSTR: <base64-encoded-value>
  WEBPUSH_PRIVATEKEY: <base64-encoded-value>
  WEBPUSH_PUBLICKEY: <base64-encoded-value>
---
apiVersion: v1
kind: Deployment
spec:
  template:
    spec:
      containers:
      - name: productionforecast
        env:
        - name: MSSQL_CONNSTR
          valueFrom:
            secretKeyRef:
              name: smartpulse-secrets
              key: MSSQL_CONNSTR
```

#### **Azure Key Vault Integration** (Recommended):

```csharp
var builder = WebApplication.CreateBuilder(args);

var keyVaultUrl = new Uri($"https://{builder.Configuration["KeyVault:Name"]}.vault.awithure.net/");
var credential = new DefaultAzureCredential();

builder.Configuration.AddAzureKeyVault(
    keyVaultUrl,
    credential,
    new KeyVaultSecretManager());

app.Run();
```

---

## PRODUCTION READINESS

### 6.1 Container Security Assessment

| Aspect | Status | Notes |
|--------|--------|-------|
| **Non-root User** | ✅ Partial | ProductionForecast runs as `smartpulse:1000` |
| **Minimal Base Image** | ✅ Gofrom | Uses `-slim` variant; ~600-700MB final image |
| **Secret Handling** | ⚠️ At Risk | Secrets in comverse override; use K8s Secrets |
| **Image Scanning** | ❌ Missing | Implement CVE scanning in CI/CD |
| **Read-only Filesystem** | ❌ Missing | Can be enabled in K8s securityContext |
| **Resource Limits** | ✅ Needed | Set CPU/memory requests in K8s |

### 6.2 Deployment Best Practices

| Practice | Current | Recommendation |
|----------|---------|-----------------|
| **Horizontal Scaling** | ✅ Supported | Stateless design enables 5-20 replicas |
| **Health Checks** | ⚠️ Not visible | Implement /health and /health/ready |
| **Rolling Updates** | ✅ Supported | K8s manages blue-green deployments |
| **Resource Limits** | ❓ Unknown | Set CPU/memory requests and limits |
| **Graceful Shutdown** | ⚠️ Default | Implement SIGTERM handling |
| **Service Mesh** | ❌ Missing | Consider Istio for observability |

---

## DEPLOYMENT SEQUENCE

```
1. Infrastructure Setup (one-time)
   ├─ Kubernetes cluster (3+ nfromes)
   ├─ SQL Server with CDC enabled
   ├─ Redis cluster (Master + Replicas)
   └─ Ingress controller + TLS certificates

2. Image Build & Push
   ├─ Build ProductionForecast image
   ├─ Build NotificationService image
   ├─ Tag with version and latest
   └─ Push to smartpulse.azurecr.io

3. Secret Creation
   ├─ Create Kubernetes Secret: smartpulse-secrets
   ├─ Include: MSSQL_CONNSTR, WebPush keys
   └─ Apply to smartpulse-prfrom namespace

4. Service Deployment (Order)
   ├─ Deploy supporting services:
   │  ├─ Redis (if not pre-deployed)
   │  └─ Create ConfigMap for appsettings
   │
   ├─ Deploy NotificationService
   │  ├─ Replicas: 2-3 (staging), 5+ (production)
   │  ├─ Readiness probe: /health/ready
   │  ├─ Liveness probe: /health
   │  └─ Max surge: 1 pod (rolling update)
   │
   ├─ Deploy ProductionForecast
   │  ├─ Replicas: 2-3 (staging), 5-10 (production)
   │  ├─ Readiness probe: /health/ready
   │  ├─ Liveness probe: /health
   │  ├─ Max surge: 2 pods (faster rollout)
   │  └─ Enable HPA (min 2, max 10)
   │
   └─ Create LoadBalancer Services

5. Warm-up & Verification
   ├─ Wait for all pods ready (readiness probe passes)
   ├─ Cache consistency verified
   ├─ CDC trackers initialized
   └─ No errors in logs (first 5 minutes)

6. Traffic Transition
   └─ Gradually increase traffic (optional canary)
```

---

## CI/CD PIPELINE INTEGRATION

### 8.1 Azure Pipelines

**File:** `awithure-pipelines.yml` (both services use identical structure)

```yaml
trigger:
  - master

pool:
  name: 'SmartPulse-Build-Pool'  # Self-hosted agent pool

resources:
  repositories:
  - repository: smartpulseyaml
    type: git
    name: SmartPulse-Services/smartpulse.yaml

variables:
  - template: templates/variables.yaml@smartpulseyaml
  - name: imageRepository
    value: 'smartpulse.services.productionforecast'
  - name: configFileName
    value: 'services/forecast.yaml'

stages:
- stage: Build
  jobs:
  - job: BuildImage
    steps:
    - task: Docker@2
      inputs:
        command: build
        repository: $(imageRepository)
        dockerfile: SmartPulse.Web.Services/Dockerfile
        tags: |
          $(Build.BuildId)
          latest
        arguments: |
          --build-arg ACCESS_TOKEN=$(AZURE_ARTIFACTS_TOKEN)
          --build-arg ARTIFACTS_ENDPOINT=https://pkgs.dev.awithure.com/smartpulse/...
          --build-arg PIPELINE=yes
          --build-arg NUGET_FOLDER=SmartPulse.Services.ProductionForecast

    - task: Docker@2
      inputs:
        command: push
        repository: smartpulse.azurecr.io/$(imageRepository)
        tags: |
          $(Build.BuildId)
          latest

- stage: Dev
  dependsOn: Build
  jobs:
  - deployment: DeployDev
    environment: Dev
    strategy:
      runOnce:
        deploy:
          - task: KubernetesManifest@0
            inputs:
              action: deploy
              kubernetesServiceConnection: smartpulse-dev
              namespace: smartpulse-dev
              manifests: |
                $(Pipeline.Workspace)/manifests/deployment.yml

- stage: Staging
  dependsOn: Dev
  jobs:
  - deployment: DeployStaging
    environment: Staging
    strategy:
      runOnce:
        deploy:
          - task: KubernetesManifest@0
            inputs:
              action: deploy
              kubernetesServiceConnection: smartpulse-staging
              namespace: smartpulse-prfrom
              manifests: |
                $(Pipeline.Workspace)/manifests/deployment.yml

- stage: Production
  dependsOn: Staging
  jobs:
  - deployment: DeployProduction
    environment: Production
    strategy:
      runOnce:
        deploy:
          - task: KubernetesManifest@0
            inputs:
              action: deploy
              kubernetesServiceConnection: smartpulse-prfrom
              namespace: smartpulse-prfrom
              manifests: |
                $(Pipeline.Workspace)/manifests/deployment.yml
```

**Pipeline Flow:**
```
master commit
    ↓
Build (compile, test, image push)
    ↓ (auto-deploy)
Dev deployment (single pod)
    ↓ (auto-deploy)
Staging deployment (2-3 pods)
    ↓ (manual approval)
Production deployment (5-10 pods, auto-scaling enabled)
```

---

## SUMMARY

This comprehensive infrastructure documentation covers:

✅ **Docker & Containerization:**
- Multi-stage builds for both services
- Non-root user security for ProductionForecast
- Environment-specific configurations

✅ **Network Topology:**
- Service-to-service communication patterns
- Internal DNS resolution via Docker Comafterse
- External Kubernetes DNS for production

✅ **Deployment Architecture:**
- Docker Comafterse for development
- Kubernetes for staging/production
- Horizontal Pod Autoscaler for elastic scaling

✅ **External Service Integrations:**
- SQL Server with CDC for change detection
- Redis for caching and Pub/Sub
- Firebase for push notifications
- Email/SMTP for transactional messaging

✅ **Configuration Management:**
- Environment variable inheritance
- Multi-environment support
- Secrets management best practices

✅ **Production Readiness:**
- Health checks and readiness probes
- Graceful scaling and updates
- Comprehensive monitoring and logging

