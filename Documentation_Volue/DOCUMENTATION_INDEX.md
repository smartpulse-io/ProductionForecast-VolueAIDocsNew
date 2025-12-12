# SmartPulse Documentation Index

**Quick Navigation Guide** | Last Updated: 2025-11-13

---

## 📋 Table of Contents

### 🚀 START HERE
1. **[PROJECT_SUMMARY.md](./PROJECT_SUMMARY.md)** - Executive overview, architecture, tech stack
2. **[docs/README.md](./docs/README.md)** - Documentation index and quick start

### 📐 Architecture & Design
- **[System Overview](./docs/architecture/00_system_overview.md)** - Microservices topology, data flow, deployment model
- **[Architectural Patterns](./docs/architecture/architectural_patterns.md)** - Design principles, communication patterns, resilience strategies
- **[Data Flow & Communication](./docs/architecture/data_flow_communication.md)** - Detailed data flows, API contracts, event schemas, cache invalidation

### 🔧 Components
- **[Electric.Core Framework](./docs/components/electric_core.md)** - Infrastructure library, Pulsar, caching, collections, CDC, pipeline

#### Production Forecast Service
- **[Overview](./docs/components/production_forecast/README.md)** - Service architecture, domain models, API overview
- **[Web API Layer](./docs/components/production_forecast/web_api_layer.md)** - REST endpoints, GraphQL subscriptions, middleware
- **[Business Logic & Caching](./docs/components/production_forecast/business_logic_caching.md)** - 4-layer caching strategy, cache invalidation, CDC integration

#### Notification Service
- **[Overview](./docs/components/notification_service/README.md)** - Service architecture, notification channels, queue patterns
- **[Service Architecture](./docs/components/notification_service/service_architecture.md)** - Worker patterns, queue processing, scalability
- **[Data Models & Integration](./docs/components/notification_service/data_models_integration.md)** - Domain models, database schema, CDC integration
- **[API Endpoints](./docs/components/notification_service/api_endpoints.md)** - REST API, GraphQL mutations, rate limiting

#### Infrastructure & Core
- **[Infrastructure Components](./docs/components/infrastructure/README.md)** - Shared utilities, logging, monitoring, health checks
- **[Distributed Data Manager](./docs/components/04_distributed_data_manager.md)** - Deep dive on version-based sync, JSON Patch, conflict resolution

### 🔌 Integration
- **[Pulsar Integration](./docs/integration/pulsar.md)** - Message bus, topics, producers, consumers, error handling
- **[Redis Integration](./docs/integration/redis.md)** - Distributed cache, Pub/Sub, field-level sync
<!-- - **[API Documentation](./docs/integration/api.md)** - REST endpoints, authentication, response formats -->

### 💾 Data Layer
- **[EF Core Strategy](./docs/data/ef_core.md)** - DbContext design, caching, interceptors, query optimization
- **[Change Data Capture](./docs/data/cdc.md)** - SQL Server CDC implementation, change tracking
<!-- - **[Database Schema](./docs/data/schema.md)** - ER diagrams, indexes, relationships -->

### 🏗️ Patterns & Best Practices
- **[Design Patterns](./docs/patterns/design_patterns.md)** - Repository, CQRS, Event Sourcing, Saga, Circuit Breaker
- **[Batch Processing](./docs/patterns/batch_processing.md)** - Bulk operations, ETL patterns, performance optimization
- **[Distributed Synchronization](./docs/patterns/distributed_sync.md)** - CRDT-like sync, version-based optimistic locking, conflict resolution
- **[Worker Patterns](./docs/patterns/worker_patterns.md)** - Background services, hosted services, job scheduling
- **[Caching Patterns](./docs/patterns/caching_patterns.md)** - Multi-level cache, cache-aside, invalidation strategies

### 📚 Developer Guides
- **[Setup Guide](./docs/guides/setup.md)** - Getting started, local environment, Docker setup
- **[Deployment Guide](./docs/guides/deployment.md)** - Kubernetes deployment, scaling, monitoring, CI/CD
- **[Performance Guide](./docs/guides/performance.md)** - Optimization techniques, profiling, benchmarks
- **[Troubleshooting Guide](./docs/guides/troubleshooting.md)** - Common issues and solutions

### 📝 Analysis Notes
<!-- Level_0, Level_1, Level_2 notes directories exist but are for internal analysis -->
- **Level_0 Notes** - Raw code analysis per component (internal analysis files)
  - `electric_core/part_1_core_infrastructure.md` - Pulsar, Caching, Collections, Workers
  - `electric_core/part_2_distributed_services.md` - DistributedData, Electricity, CDC, Pipeline
  - `production_forecast/` - API, business logic, caching
  - `notification_service/` - Notifications, email queue
  - `infrastructure/` - EF Core, interceptors
- **Level_1 Notes** - Component synthesis (internal analysis files)
- **Level_2 Notes** - Architecture and patterns (internal analysis files)

### 📋 Planning & Decisions
<!-- Plan directories exist but are for internal planning -->
- **Implementation Plans** - Project phases, task definitions (internal planning files)
- **Execution Logs** - Progress tracking, decisions made (internal planning files)

---

## 🔍 Find Information By...

### By Technology
- **Apache Pulsar** → `docs/integration/pulsar.md`, `docs/components/electric_core.md`
- **Redis** → `docs/integration/redis.md`, `docs/patterns/distributed_data.md`
- **SQL Server/PostgreSQL** → `docs/data/ef_core.md`, `docs/data/cdc.md`
- **Entity Framework Core** → `docs/data/ef_core.md`, `docs/components/production_forecast.md`
- **GraphQL** → `docs/api/graphql.md`
- **ASP.NET Core** → `docs/components/production_forecast.md`, `docs/components/notification_service.md`

### By Concern
- **Performance** → `docs/architecture/00_system_overview.md` (metrics), `docs/guides/performance.md`, `docs/data/ef_core.md` (query optimization)
- **Scalability** → `docs/patterns/concurrency.md`, `docs/patterns/distributed_data.md`, `docs/components/electric_core.md`
- **Reliability** → `docs/integration/pulsar.md` (error handling), `docs/guides/troubleshooting.md`
- **Security** → `docs/guides/code_review.md` (security checks), `docs/integration/api.md`
- **Caching** → `docs/patterns/distributed_data.md`, `docs/components/production_forecast.md` (multi-level cache)
- **Real-time Updates** → `docs/patterns/distributed_data.md` (CDC), `docs/integration/pulsar.md` (events)

### By Service/Component
- **ProductionForecast Service**
  - Architecture: `docs/components/production_forecast.md`
  - API: `docs/integration/api.md` (endpoints)
  - Caching: `docs/components/production_forecast.md` (cache strategy)
  - Database: `docs/data/ef_core.md` (DbContext)
  - CDC: `docs/data/cdc.md` (cache invalidation)

- **NotificationService**
  - Architecture: `docs/components/notification_service.md`
  - Workers: `docs/components/electric_core.md` (AutoBatchWorker)
  - Database: `docs/components/notification_service.md` (DbContext)

- **Electric.Core Library**
  - Overview: `docs/components/electric_core.md`
  - Pulsar: `docs/integration/pulsar.md`
  - Collections: `docs/components/electric_core.md`, `docs/patterns/concurrency.md`
  - Distributed Data: `docs/patterns/distributed_data.md`
  - CDC: `docs/data/cdc.md`

### By Audience
- **New Developer** → START: `PROJECT_SUMMARY.md` → `docs/guides/setup.md` → `docs/components/production_forecast.md`
- **Architect** → `docs/architecture/00_system_overview.md` → `docs/patterns/` → `PROJECT_SUMMARY.md`
- **DBA** → `docs/data/schema.md`, `docs/data/ef_core.md` (query performance), `docs/data/cdc.md`
- **DevOps/SRE** → `docs/guides/setup.md`, `docs/architecture/00_system_overview.md` (deployment), `docs/guides/troubleshooting.md`
- **Performance Engineer** → `docs/guides/performance.md`, `PROJECT_SUMMARY.md` (characteristics), `docs/components/electric_core.md` (collections)

---

## 🎯 Common Tasks

### I want to...

#### Add a new API endpoint
1. **Check existing endpoints**: `docs/integration/api.md`
2. **Add controller action**: `docs/components/production_forecast.md` (API section)
3. **Update cache tags**: `docs/patterns/distributed_data.md` (cache invalidation)
4. **Write tests**: `docs/guides/code_review.md` (testing guidelines)
5. **Document**: Update `docs/integration/api.md`

#### Debug performance issues
1. **Check metrics**: `docs/architecture/00_system_overview.md` (performance characteristics)
2. **Query optimization**: `docs/data/ef_core.md` (query execution plans)
3. **Cache hit ratios**: `docs/components/production_forecast.md` (cache diagnostics)
4. **CDC lag**: `docs/data/cdc.md` (monitoring)
5. **Tools**: `docs/guides/performance.md` (profiling tools)

#### Add a new distributed cache
1. **Create manager**: `docs/patterns/distributed_data.md` (DistributedDataManager<T>)
2. **Register in DI**: `docs/components/electric_core.md` (dependency injection)
3. **Add CDC tracker**: `docs/data/cdc.md` (cache invalidation)
4. **Test synchronization**: `docs/patterns/distributed_data.md` (CRDT testing)

#### Integrate new Pulsar topic
1. **Register producer**: `docs/integration/pulsar.md` (SmartpulsePulsarClient)
2. **Create consumer**: `docs/integration/pulsar.md` (consumer patterns)
3. **Add event model**: `docs/components/production_forecast.md` (models structure)
4. **Error handling**: `docs/integration/pulsar.md` (retry logic)

#### Scale the system
1. **Read**: `docs/architecture/00_system_overview.md` (scalability strategies)
2. **Horizontal**: Stateless services with Redis/Pulsar
3. **Vertical**: Review `docs/components/electric_core.md` (concurrency patterns)
4. **Database**: `docs/data/ef_core.md` (bulk operations, indexes)

#### Monitor production
1. **Metrics to track**: `PROJECT_SUMMARY.md` (performance characteristics)
2. **Alerting setup**: `docs/architecture/00_system_overview.md` (observability)
3. **Logs**: `docs/guides/troubleshooting.md` (structured logging)
4. **Health checks**: `docs/guides/setup.md` (health endpoints)

#### Write unit tests
1. **Guidelines**: `docs/guides/code_review.md` (testing best practices)
2. **Test containers**: `docs/guides/setup.md` (integration test setup)
3. **Examples**: Check test projects in Source/

#### Migrate database schema
1. **EF Core migrations**: `docs/data/ef_core.md` (migration strategy)
2. **Apply order**: `docs/guides/setup.md` (migration order)
3. **Rollback**: `docs/guides/troubleshooting.md` (migration rollback)

---

## 📊 File Statistics

| Category | Files | Lines | Purpose |
|----------|-------|-------|---------|
| Architecture | 3 | 2500+ | System design, patterns, data flows |
| Components | 11 | 5500+ | ProductionForecast (3), NotificationService (4), Infrastructure (2), Electric.Core (1), Distributed Data (1) |
| Integration | 2 | 1200+ | Pulsar, Redis setup and patterns |
| Data Layer | 2 | 1000+ | EF Core, Change Data Capture |
| Patterns | 5 | 2200+ | Design patterns, batch processing, worker patterns, caching, distributed sync |
| Guides | 4 | 2000+ | Setup, deployment, performance, troubleshooting |
| **Total Documentation** | **31** | **23,200+** | Comprehensive system architecture and implementation guides |

---

## 🔗 Key Diagrams

All diagrams are in Mermaid format (markdown code blocks) in documentation files:

1. **Microservices Topology** → `docs/architecture/00_system_overview.md`
2. **Data Flow (Write Path)** → `docs/architecture/00_system_overview.md`
3. **Electric.Core Architecture** → `docs/components/electric_core.md`
4. **Partitioned Queue Evolution** → `docs/components/electric_core.md`
5. **Cache Invalidation Flow** → `docs/patterns/distributed_data.md`
6. **Thread-Safety Strategies** → `docs/patterns/concurrency.md`
7. **ProductionForecast API Flow** → `docs/components/production_forecast.md`
8. **Notification Flow** → `docs/components/notification_service.md`

---

## ⚙️ Configuration & Setup

- **Local Development**: `docs/guides/setup.md`
- **Docker Compose**: `docker-compose.yml` (in project root)
- **Environment Variables**: See `docs/guides/setup.md`
- **Database Migrations**: `docs/guides/setup.md` (EF Core commands)

---

## 🆘 Troubleshooting

Quick links to solutions:
- **Cache not invalidating**: See `docs/data/cdc.md` + `docs/patterns/distributed_data.md`
- **Slow API response**: See `docs/guides/performance.md` + `docs/data/ef_core.md`
- **Pulsar messages not processed**: See `docs/integration/pulsar.md`
- **Redis connection issues**: See `docs/guides/troubleshooting.md`
- **Database migration failed**: See `docs/guides/troubleshooting.md`

---

## 📚 Learning Path

### For Beginners (New to project)
1. Read: `PROJECT_SUMMARY.md` (10 min)
2. Read: `docs/architecture/00_system_overview.md` sections 1-2 (15 min)
3. Setup: `docs/guides/setup.md` (30 min)
4. Explore: `docs/components/production_forecast.md` (20 min)
5. Run: Sample API requests in `docs/integration/api.md` (10 min)

### For Architects (System design review)
1. Read: `PROJECT_SUMMARY.md` (15 min)
2. Read: `docs/architecture/00_system_overview.md` (30 min)
3. Read: `docs/patterns/` folder (45 min)
4. Review: `docs/components/electric_core.md` (30 min)
5. Assess: Known limitations in `PROJECT_SUMMARY.md`

### For Performance Engineers
1. Read: `PROJECT_SUMMARY.md` (performance characteristics section)
2. Read: `docs/guides/performance.md` (30 min)
3. Read: `docs/data/ef_core.md` (query optimization)
4. Read: `docs/components/electric_core.md` (collections, concurrency)
5. Tools: See `PROJECT_SUMMARY.md` (tools & resources)

---

## 📞 Support

- **Documentation Issues**: Check if addressed in `docs/guides/troubleshooting.md`
- **Architecture Questions**: See `docs/architecture/00_system_overview.md`
- **Component Specifics**: See respective file in `docs/components/`
- **Implementation Details**: See `notes/level_0/` raw analysis

---

## 📄 Document Maintenance

- **Last Updated**: 2025-11-13
- **Version**: 2.0
- **Total Files**: 31 documentation files across 7 major sections
- **Total Lines**: 23,200+ lines of documentation
- **Review Schedule**: Quarterly
- **Update Process**: Maintain consistency across all files
- **Archive**: Previous versions in git history

---

**Documentation Sections**:
- Architecture (System Overview, Architectural Patterns, Data Flow)
- Components (ProductionForecast, NotificationService, Infrastructure, Electric.Core)
- Integration (Pulsar, Redis)
- Data Layer (EF Core, CDC)
- Patterns (Design, Batch Processing, Distributed Sync, Workers, Caching)
- Guides (Setup, Deployment, Performance, Troubleshooting)
- Analysis Notes (Level_0, Level_1, Level_2)
