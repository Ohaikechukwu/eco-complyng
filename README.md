# EcoComply NG

Environmental Compliance and Inspection Reporting Platform.

## Stack
- **Backend:** Go/Gin (microservices)
- **Web:** Next.js
- **Mobile:** React Native
- **Database:** PostgreSQL (per-org isolated schema)
- **Cache:** Redis
- **Media:** Cloudinary
- **PDF:** chromedp

## Services
- `auth-service`
- `inspection-service`
- `media-service`
- `report-service`
- `collaboration-service`
- `notification-service`
- `export-service`

## Quick Start

```bash
make docker-up        # Start full stack
make migrate-up       # Run all migrations
make run-gateway      # Start API gateway
```

See each service's `.env.example` for required environment variables.
