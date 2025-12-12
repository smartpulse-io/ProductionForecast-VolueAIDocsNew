# Developer Guide - Environment Setup & Configuration

Complete guide for setting up your local development environment for SmartPulse MCP Proxy.


## ⚠️ CRITICAL - ProductionForecast Service Scope

**This document may describe infrastructure capabilities (Redis, Pulsar, etc.).**

**ProductionForecast ACTUALLY uses ONLY:**
- ✅ IMemoryCache (local in-memory cache)
- ✅ Electric.Core for CDC (Change Data Capture ONLY)
- ✅ Entity Framework Core

**ProductionForecast does NOT use:**
- ❌ Redis
- ❌ Apache Pulsar
- ❌ Distributed caching
- ❌ Message bus

Other services (NotificationService) may use these technologies.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Local Development Environment](#local-development-environment)
3. [Database Setup](#database-setup)
4. [Cluster Setup](#-cluster-setup)
5. [Redis Setup](#redis-setup)
6. [Project Structure & Build](#project-structure--build)
7. [Running Services Locally](#running-services-locally)
8. [Configuration Management](#configuration-management)
9. [IDE Setup](#ide-setup)
10. [First Run Checklist](#first-run-checklist)

---

## Prerequisites

### System Requirements

**Operating Systems:**
- **Windows 10+** - Professional or Home Edition (64-bit recommended)
- **macOS 10.15+** - Sonoma or later (Intel or Apple Silicon)
- **Ubuntu 20.04+** - LTS recommended (WSL2 supported on Windows)

**Runtime & Development Tools:**
- **.NET 9 SDK** - Latest stable version (`dotnet --version` to verify)
- **Node.js 16+** - For Pug template rendering (npm included)
- **Docker Desktop 20.10+** - Include Docker Compose, Linux containers mode enabled
- **Git 2.30+** - Version control system (SSH keys recommended)
- **VS Code or Visual Studio** - IDE for development (C# extensions required)

**Infrastructure & Resources:**
- **SQL Server 2019+** - Developer Edition (free), CDC must be enabled
- **Redis 6.0+** - In-memory cache (persistence recommended)
- **Memory** - Minimum 4GB, Recommended 8GB+
- **Storage** - Minimum 20GB free space (SSD recommended)

### ProductionForecast Requirements (Minimal)

**For ProductionForecast service ONLY**:

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'20px', 'primaryColor':'#27ae60', 'primaryBorderColor':'#2c3e50'}}}%%
graph TB
    subgraph OS["🖥️ OPERATING SYSTEM"]
        B1["Windows 10+<br/>64-bit"]
        B2["macOS 10.15+<br/>Intel/Apple"]
        B3["Ubuntu 20.04+<br/>LTS"]
    end

    subgraph TOOLS["🛠️ DEVELOPMENT TOOLS"]
        C1[".NET 9 SDK"]
        C2["Docker 20.10+"]
        C3["Git 2.30+"]
        C4["IDE<br/>(VS/VS Code)"]
    end

    subgraph INFRA["🗄️ REQUIRED INFRASTRUCTURE"]
        D1["SQL Server 2019+<br/>(with CDC enabled)"]
    end

    subgraph RESOURCES["💾 RESOURCES"]
        E1["4GB RAM min<br/>8GB+ recommended"]
        E2["10GB disk free<br/>SSD ideal"]
    end

    style OS fill:#3498db,stroke:#2c3e50,color:#fff,stroke-width:3px
    style TOOLS fill:#e67e22,stroke:#2c3e50,color:#fff,stroke-width:3px
    style INFRA fill:#27ae60,stroke:#2c3e50,color:#fff,stroke-width:3px
    style RESOURCES fill:#95a5a6,stroke:#2c3e50,color:#fff,stroke-width:3px
```

**ProductionForecast does NOT require**: Redis, Apache Pulsar, or Node.js.

---

### Full Infrastructure Requirements (All Services)

**For complete SmartPulse platform** (includes NotificationService):

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'20px', 'primaryColor':'#00897b', 'primaryBorderColor':'#004d40', 'primaryTextColor':'#fff'}}}%%
graph TB
    subgraph OS["🖥️ OPERATING SYSTEM"]
        B1["Windows 10+<br/>64-bit"]
        B2["macOS 10.15+<br/>Intel/Apple"]
        B3["Ubuntu 20.04+<br/>LTS"]
    end

    subgraph TOOLS["🛠️ DEVELOPMENT TOOLS"]
        C1[".NET 9 SDK"]
        C2["Node.js 16+"]
        C3["Docker 20.10+"]
        C4["Git 2.30+"]
        C5["IDE"]
    end

    subgraph INFRA["🗄️ INFRASTRUCTURE"]
        D1["SQL Server 2019+"]
        D2["Apache Pulsar 3.0+<br/>(NotificationService)"]
        D3["Redis 6.0+<br/>(NotificationService)"]
    end

    subgraph RESOURCES["💾 RESOURCES"]
        E1["4GB RAM min<br/>8GB+ recommended"]
        E2["20GB disk free<br/>SSD ideal"]
    end

    style OS fill:#00897b,stroke:#004d40,color:#fff,stroke-width:3px
    style B1 fill:#e0f2f1,stroke:#00897b,stroke-width:2px,color:#000
    style B2 fill:#e0f2f1,stroke:#00897b,stroke-width:2px,color:#000
    style B3 fill:#e0f2f1,stroke:#00897b,stroke-width:2px,color:#000

    style TOOLS fill:#f57c00,stroke:#e65100,color:#fff,stroke-width:3px
    style C1 fill:#fff3e0,stroke:#f57c00,stroke-width:2px,color:#000
    style C2 fill:#fff3e0,stroke:#f57c00,stroke-width:2px,color:#000
    style C3 fill:#fff3e0,stroke:#f57c00,stroke-width:2px,color:#000
    style C4 fill:#fff3e0,stroke:#f57c00,stroke-width:2px,color:#000
    style C5 fill:#fff3e0,stroke:#f57c00,stroke-width:2px,color:#000

    style INFRA fill:#e65100,stroke:#bf360c,color:#fff,stroke-width:3px
    style D1 fill:#ffe0b2,stroke:#e65100,stroke-width:2px,color:#000
    style D2 fill:#ffe0b2,stroke:#e65100,stroke-width:2px,color:#000
    style D3 fill:#ffe0b2,stroke:#e65100,stroke-width:2px,color:#000

    style RESOURCES fill:#00796b,stroke:#004d40,color:#fff,stroke-width:3px
    style E1 fill:#b2dfdb,stroke:#00897b,stroke-width:2px,color:#000
    style E2 fill:#b2dfdb,stroke:#00897b,stroke-width:2px,color:#000
```

### Installation Commands

<details>
<summary>Windows (with Chocolatey)</summary>

```powershell
# Install .NET 9 SDK
choco install dotnet-sdk

# Install Node.js
choco install nodejs

# Install Docker Desktop
choco install docker-desktop

# Install Git
choco install git

# Install Visual Studio Community (optional)
choco install visualstudio2022community
```
</details>

<details>
<summary>macOS (with Homebrew)</summary>

```bash
# Install .NET 9 SDK
brew install dotnet

# Install Node.js
brew install node

# Install Docker Desktop
brew install docker

# Install Git
brew install git
```
</details>

<details>
<summary>Ubuntu/Linux</summary>

```bash
# Install .NET 9 SDK
wget https://dot.net/v1/dotnet-install.sh -O dotnet-install.sh
chmod +x dotnet-install.sh
./dotnet-install.sh --version latest

# Install Node.js
sudo apt-get install nodejs npm

# Install Docker
sudo apt-get install docker.io docker-compose

# Install Git
sudo apt-get install git
```
</details>

---

## Local Development Environment

### Architecture Overview

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'18px', 'primaryColor':'#0288d1'}}}%%
graph TB
    A["<b>Developer Workstation</b><br/>Your Machine"]

    A --> B["<b>🐳 Docker Compose</b><br/>Infrastructure Services"]
    A --> D["<b>💻 Local IDE</b><br/>Service Development"]

    B --> C1["SQL Server<br/>Container<br/>Port 1433"]
    B --> C3["Redis<br/>Container<br/>Port 6379"]

    D --> D1["ProductionForecast.API<br/>https://localhost:5000<br/>dotnet run"]
    D --> D2["NotificationService.API<br/>https://localhost:5001<br/>dotnet run"]

    D1 --> E1["SQL Server"]
    D1 --> E2[""]
    D1 --> E3["Redis"]
    D2 --> E1
    D2 --> E2
    D2 --> E3

    C1 -.->|connects| E1
    C2 -.->|connects| E2
    C3 -.->|connects| E3

    style A fill:#0288d1,stroke:#01579b,color:#fff,stroke-width:3px
    style B fill:#7b1fa2,stroke:#4a148c,color:#fff,stroke-width:2px
    style D fill:#388e3c,stroke:#1b5e20,color:#fff,stroke-width:2px

    style C1 fill:#fff3e0,stroke:#f57c00,stroke-width:2px,color:#000
    style C2 fill:#fff3e0,stroke:#f57c00,stroke-width:2px,color:#000
    style C3 fill:#fff3e0,stroke:#f57c00,stroke-width:2px,color:#000

    style D1 fill:#e0f2f1,stroke:#00897b,stroke-width:2px,color:#000
    style D2 fill:#e0f2f1,stroke:#00897b,stroke-width:2px,color:#000

    style E1 fill:#ffebee,stroke:#c62828,stroke-width:2px,color:#000
    style E2 fill:#ffebee,stroke:#c62828,stroke-width:2px,color:#000
    style E3 fill:#ffebee,stroke:#c62828,stroke-width:2px,color:#000
```

### Docker Compose Setup

Create `docker-compose.local.yml` in project root:

<details>
<summary>docker-compose.local.yml</summary>

```yaml
version: '3.8'

services:
  # SQL Server Development Database
  sqlserver:
    image: mcr.microsoft.com/mssql/server:2019-latest
    container_name: smartpulse-sqlserver-dev
    environment:
      SA_PASSWORD: "DevPassword123!"
      ACCEPT_EULA: "Y"
      MSSQL_PID: "Developer"
    ports:
      - "1433:1433"
    volumes:
      - sqlserver_data:/var/opt/mssql
    healthcheck:
      test: ["CMD", "/opt/mssql-tools/bin/sqlcmd", "-U", "sa", "-P", "DevPassword123!", "-Q", "SELECT 1"]
      interval: 10s
      timeout: 3s
      retries: 10
    networks:
      - smartpulse-network

  :
    image: apache/:3.0.0
    container_name: smartpulse--dev
    command: bin/standalone
    ports:
      - "6650:6650"
      - "8080:8080"
      - "6651:6651"  # TLS port (self-signed)
    environment:
      - _LOG_LEVEL=WARN
    volumes:
      - _data://data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/admin/v2/brokers"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - smartpulse-network

  # Redis Cache
  redis:
    image: redis:7-alpine
    container_name: smartpulse-redis-dev
    command: redis-server --requirepass redis-dev-password
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 10
    networks:
      - smartpulse-network

networks:
  smartpulse-network:
    driver: bridge

volumes:
  sqlserver_data:
  _data:
  redis_data:
```
</details>

### Start Development Environment

```bash
# Start all containers
docker-compose -f docker-compose.local.yml up -d

# Verify all services are healthy
docker-compose -f docker-compose.local.yml ps

# View logs
docker-compose -f docker-compose.local.yml logs -f

# Stop all containers
docker-compose -f docker-compose.local.yml down

# Clean everything (including volumes)
docker-compose -f docker-compose.local.yml down -v
```

---

## Database Setup

### Database Initialization Flow

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Developer Machine"]
    A --> B["Run EF Core<br/>Migrations"]

    B --> C["Create<br/>SmartPulseDb"]
    C --> D["Create Tables<br/>& Indexes"]

    D --> E["Enable CDC<br/>on Tables"]
    E --> F["Seed Test Data"]
    F --> G["Database Ready"]

    style A fill:#e3f2fd,stroke:#0288d1,stroke-width:3px
    style B fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    style C fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    style D fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    style E fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    style F fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    style G fill:#c8e6c9,stroke:#388e3c,stroke-width:3px
```

### SQL Server Connection

```bash
# Create database (via migration)
cd src/Infrastructure/SmartPulse.Data

# Initial migration
dotnet ef migrations add InitialCreate --startup-project ../../Presentation/SmartPulse.API

# Apply migration
dotnet ef database update --startup-project ../../Presentation/SmartPulse.API
```

### appsettings.Development.json

```json
{
  "ConnectionStrings": {
    "DefaultConnection": "Server=localhost,1433;Database=SmartPulseDb;User Id=sa;Password=DevPassword123!;TrustServerCertificate=true;",
    "Redis": "localhost:6379,password=redis-dev-password",
    "": "://localhost:6650"
  },
  "Logging": {
    "LogLevel": {
      "Default": "Debug",
      "Microsoft": "Information",
      "Microsoft.EntityFrameworkCore": "Debug"
    }
  },
  "": {
    "ServiceUrl": "://localhost:6650",
    "OperationTimeoutSeconds": 30
  },
  "Redis": {
    "Connection": "localhost:6379",
    "Password": "redis-dev-password"
  }
}
```

### Enable CDC on Tables

```sql
-- Connect to SmartPulseDb as sa
USE SmartPulseDb;

-- Enable CDC on database
EXEC sys.sp_cdc_enable_db;

-- Enable CDC on Forecasts table
EXEC sys.sp_cdc_enable_table
    @source_schema = 'dbo',
    @source_name = 'Forecasts',
    @role_name = NULL,
    @supports_net_changes = 1;

-- Enable CDC on Notifications table
EXEC sys.sp_cdc_enable_table
    @source_schema = 'dbo',
    @source_name = 'Notifications',
    @role_name = NULL,
    @supports_net_changes = 1;

-- Enable CDC on SystemVariables table
EXEC sys.sp_cdc_enable_table
    @source_schema = 'dbo',
    @source_name = 'SystemVariables',
    @role_name = NULL,
    @supports_net_changes = 1;

-- Verify CDC is enabled
SELECT name, is_tracked_by_cdc
FROM sys.tables
WHERE is_tracked_by_cdc = 1;
```

---

## Cluster Setup

### Development Setup

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Standalone<br/>Container"]

    A --> B["Broker Service<br/>Port :6650"]

    B --> C1["Topic:<br/>forecast-updated"]
    B --> C2["Topic:<br/>notification-published"]

    B --> C3["Topic:<br/>cache-invalidation"]
    B --> C4["Topic:<br/>data-sync"]

    A --> D["Manager<br/>localhost:9527"]
    A --> E["REST API<br/>localhost:8080"]

    G --> B

    style A fill:#fff3e0,stroke:#f57c00,stroke-width:3px
    style B fill:#ffe0b2,stroke:#e65100,stroke-width:2px
    style C1 fill:#e0f2f1,stroke:#00897b
    style C2 fill:#e0f2f1,stroke:#00897b
    style C3 fill:#e0f2f1,stroke:#00897b
    style C4 fill:#e0f2f1,stroke:#00897b
    style D fill:#f3e5f5,stroke:#7b1fa2
    style E fill:#f3e5f5,stroke:#7b1fa2
    style F fill:#e3f2fd,stroke:#0288d1,stroke-width:2px
    style G fill:#bbdefb,stroke:#1976d2
```

### Create Topics

```bash
# Access container
docker-compose -f docker-compose.local.yml exec bash

# Create topics for local development
./bin/-admin topics create persistent://public/default/forecast-updated
./bin/-admin topics create persistent://public/default/notification-published
./bin/-admin topics create persistent://public/default/cache-invalidation
./bin/-admin topics create persistent://public/default/data-sync-topic
./bin/-admin topics create persistent://public/default/system-variables-refreshed
./bin/-admin topics create persistent://public/default/service-health-check

# List created topics
./bin/-admin topics list public/default

# Exit container
exit
```

---

## Redis Setup

### Redis Development Configuration

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Redis Instance<br/>localhost:6379"]

    A --> B["Data Structures"]
    A --> C["Pub/Sub Channels"]

    B --> B1["String Keys<br/>forecast:product:*"]
    B --> B2["Hash Keys<br/>notification:*"]
    B --> B3["Sorted Sets<br/>leaderboard:*"]

    C --> C1["cache:invalidation:*"]
    C --> C2["data-sync:*"]
    C --> C3["notifications:*"]

    style A fill:#c8e6c9,stroke:#388e3c,stroke-width:3px
    style B fill:#e8f5e9,stroke:#66bb6a,stroke-width:2px
    style C fill:#e8f5e9,stroke:#66bb6a,stroke-width:2px
    style B1 fill:#e0f2f1,stroke:#00897b
    style B2 fill:#e0f2f1,stroke:#00897b
    style B3 fill:#e0f2f1,stroke:#00897b
    style C1 fill:#fff3e0,stroke:#f57c00
    style C2 fill:#fff3e0,stroke:#f57c00
    style C3 fill:#fff3e0,stroke:#f57c00
```

### Redis Connection Test

```bash
# Connect to Redis
docker-compose -f docker-compose.local.yml exec redis redis-cli -a redis-dev-password

# Test basic operations
PING
SET test:key "Hello World"
GET test:key
DEL test:key

# Monitor Pub/Sub
MONITOR

# Check memory usage
INFO memory

# Exit
EXIT
```

---

## Running Services Locally

### Launch Strategy

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Start Development"]

    A --> B["Terminal 1:<br/>Docker Compose"]
    A --> C["Terminal 2:<br/>ProductionForecast.API"]
    A --> D["Terminal 3:<br/>NotificationService.API"]

    B --> B1["docker-compose -f<br/>docker-compose.local.yml up"]

    C --> C0["cd ~/smartpulse"]
    C0 --> C1["cd src/Presentation/<br/>ProductionForecast.API"]
    C1 --> C2["dotnet restore"]
    C2 --> C3["dotnet run"]

    D --> D0["cd ~/smartpulse"]
    D0 --> D1["cd src/Presentation/<br/>NotificationService.API"]
    D1 --> D2["dotnet restore"]
    D2 --> D3["dotnet run"]

    B1 --> E["All Services Ready"]
    C3 --> E
    D3 --> E

    E --> F["Access via<br/>Postman or Swagger"]

    style A fill:#e3f2fd,stroke:#0288d1,stroke-width:3px
    style B fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    style C fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    style D fill:#ffe0b2,stroke:#e65100,stroke-width:2px
    style E fill:#c8e6c9,stroke:#388e3c,stroke-width:3px
    style F fill:#e1bee7,stroke:#8e24aa,stroke-width:2px
```

---

## Configuration Management

### Configuration Hierarchy

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize':'16px'}}}%%
graph TB
    A["Configuration<br/>Resolution"]

    A --> B["appsettings.json<br/>Default"]
    A --> C["appsettings<br/>Development.json"]
    A --> D["appsettings<br/>Production.json"]
    A --> E["Environment<br/>Variables<br/>Override"]
    A --> F["User Secrets<br/>Development Only"]

    B -.-> G["Result:<br/>Merged Config"]
    C -.-> G
    D -.-> G
    E -.-> G
    F -.-> G

    G --> H["IConfiguration<br/>in Dependency<br/>Injection"]

    style A fill:#e3f2fd,stroke:#0288d1,stroke-width:3px
    style B fill:#e8f5e9,stroke:#66bb6a
    style C fill:#e8f5e9,stroke:#66bb6a
    style D fill:#e8f5e9,stroke:#66bb6a
    style E fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    style F fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    style G fill:#c8e6c9,stroke:#388e3c,stroke-width:3px
    style H fill:#ffe0b2,stroke:#e65100,stroke-width:2px
```

---

## First Run Checklist

### Step-by-Step First Run

```bash
# 1. Clone and navigate
git clone https://github.com/your-org/smartpulse.git
cd smartpulse

# 2. Verify .NET installation
dotnet --version  # Should be 9.0 or higher

# 3. Restore dependencies
dotnet restore

# 4. Start infrastructure services
docker-compose -f docker-compose.local.yml up -d

# 5. Verify Docker services are healthy (wait ~30 seconds)
docker-compose -f docker-compose.local.yml ps

# 6. Run database migrations
cd src/Infrastructure/SmartPulse.Data
dotnet ef database update --startup-project ../../Presentation/SmartPulse.API

# 7. Create topics
docker-compose -f docker-compose.local.yml exec \
  ./bin/-admin topics create persistent://public/default/forecast-updated

# 8. Launch ProductionForecast service
cd src/Presentation/ProductionForecast.API
dotnet run

# 9. In another terminal, launch NotificationService
cd src/Presentation/NotificationService.API
dotnet run

# 10. Test services
curl -X GET https://localhost:5001/health/live -k
curl -X GET https://localhost:5002/health/live -k

# 11. Access Swagger UIs
# Open: https://localhost:5001/swagger
# Open: https://localhost:5002/swagger
```

---

## Related Guides

- [Troubleshooting Guide](./troubleshooting.md) - Common issues and solutions
- [Performance Guide](./performance.md) - Optimization techniques
- [Deployment Guide](./deployment.md) - Production deployment
- [Component Guides](../components/README.md) - Service-specific details (see Electric Core, ProductionForecast, NotificationService)

---

## Summary

This setup guide enables you to:

✅ Set up complete local development environment with Docker
✅ Configure SQL Server with CDC enabled
✅ Configure Redis for distributed caching
✅ Run both ProductionForecast and NotificationService locally
✅ Access all services via Swagger UI
✅ Debug and develop with full infrastructure

**Next Steps:**
1. Follow the "First Run Checklist" above
2. Proceed to [Troubleshooting Guide](./troubleshooting.md) if issues occur
3. Read [Performance Guide](./performance.md) for optimization tips
