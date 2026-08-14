# Development

## Setup

First things first, you'll need to fork and clone the repository to your local machine.

`git clone https://github.com/ecosyste-ms/nexus.git`

The project uses Ruby on Rails which have a number of system dependencies you'll need to install.

- [ruby 4.0.6](https://www.ruby-lang.org/en/documentation/installation/)
- [postgresql 14](https://www.postgresql.org/download/)
- [redis 6+](https://redis.io/download/)
- The [`nexus`](https://github.com/git-pkgs/nexus) command on `PATH`

You will then need to set some configuration environment variables. Copy `.env.example` to `.env.development` and customise the values to suit your local setup.

Once you've got all of those installed, from the root directory of the project run the following commands:

```bash
bundle install
bundle exec rake db:create db:migrate
```

### Running the Application

To start the Rails server:

```bash
bundle exec rails server
```

To start Sidekiq for background jobs:

```bash
bundle exec sidekiq
```

You can then load up [http://localhost:3000/health](http://localhost:3000/health) to verify the service is running.

### Docker

The production Dockerfile builds a pinned revision of `git-pkgs/nexus` and copies the static binary to `/usr/local/bin/nexus`. Set the `NEXUS_REVISION` build argument when updating the pinned version.

## Configuration

### Environment Variables

The application uses the following environment variables:

**Database:**
- `POSTGRES_USER` - PostgreSQL username (default: postgres)
- `POSTGRES_PASSWORD` - PostgreSQL password
- `POSTGRES_HOST` - PostgreSQL host (default: localhost)
- `POSTGRES_PORT` - PostgreSQL port (default: 5432)
- `DATABASE_URL` - Full database URL (production)

**Redis:**
- `REDIS_URL` - Redis connection URL (default: redis://localhost:6379/0)

**Application:**
- `RAILS_ENV` - Rails environment (development/test/production)
- `PORT` - Application port (default: 3000)
- `NEXUS_API_KEY` - Shared key required in the `X-API-Key` header for repository sync and reindex requests

**External Services:**
- `PACKAGES_ECOSYSTE_MS_URL` - Base URL for packages.ecosyste.ms API
- `PACKAGES_ECOSYSTE_MS_API_KEY` - API key for authentication

**Configuration:**
- `REINDEX_INTERVAL_HOURS` - How often to re-index repositories (default: 24)
- `INDEX_JOB_LOCK_TTL_HOURS` - How long one repository remains locked for indexing (default: 48)
- `NEXUS_BINARY` - Path to the `nexus` command (default: `nexus`)
- `NEXUS_ALLOW_PRIVATE` - Pass `--allow-private` to the command when set to `true`

**Monitoring:**
- `APPSIGNAL_PUSH_API_KEY` - AppSignal API key (optional)
- `SIDEKIQ_USERNAME` - Sidekiq web UI username
- `SIDEKIQ_PASSWORD` - Sidekiq web UI password

## Tests

The application tests can be found in [test](test) and use the testing framework [minitest](https://github.com/minitest/minitest).

You can run all the tests with:

```bash
rails test
```

Run specific test files:

```bash
rails test test/models/repository_test.rb
```

## Background Tasks

Background tasks are handled by [Sidekiq](https://github.com/mperham/sidekiq), the workers live in [app/sidekiq](app/sidekiq/).

### Workers

**IndexRepositoryWorker**
- Indexes a single repository
- Streams `nexus sync` output into PostgreSQL and saves each verified checkpoint
- Triggered manually via API or by SyncAllRepositoriesWorker

**SyncAllRepositoriesWorker**
- Runs daily at 1 AM (configured in app.json)
- Queues IndexRepositoryWorker for all repositories that need reindexing
- A repository needs reindexing if it has never been indexed or was last indexed more than REINDEX_INTERVAL_HOURS ago

### Running Sidekiq

Sidekiq can be started with:

```bash
bundle exec sidekiq
```

You can also view the status of the workers and their queues from the web interface:
- Development: http://localhost:3000/sidekiq
- Production: http://nexus.ecosyste.ms/sidekiq (requires authentication)

## API Endpoints

### GET /health
Health check endpoint that returns application status and database connectivity.

### GET /metrics
Returns basic metrics about repositories, packages, and versions.

### GET /api/v1/repositories
Returns a list of all repositories with their metadata.

### GET /api/v1/repositories/:name
Returns details for a specific repository.

### GET /api/v1/repositories/:name/packages
Returns an array of all package names (groupId:artifactId) in the repository.

### GET /api/v1/repositories/:name/recent
Returns recently updated packages and versions. Accepts optional `since` parameter (ISO 8601 date).

### GET /api/v1/repositories/:name/status
Returns the current indexing status of a repository.

### POST /api/v1/repositories/:name/reindex
Triggers a re-index of the specified repository. Queues an IndexRepositoryWorker job.

### POST /api/v1/sync_repositories
Syncs repository list from packages.ecosyste.ms. Expects JSON array of repository objects:

```json
[
  {
    "name": "build.shibboleth.net",
    "url": "https://build.shibboleth.net/nexus/content/repositories/releases",
    "ecosystem": "maven"
  }
]
```

## Architecture

### Maven Index Processing Flow

1. Run `nexus sync` with the repository URL and the last committed cursor.
2. Stream artifact events into a temporary PostgreSQL table with `COPY`.
3. Merge artifact, package, and version state when the command emits a verified checkpoint.
4. Save the checkpoint in the same transaction as its events.

### File Format

The command writes newline-delimited JSON:

```json
{"type":"sync","mode":"incremental","index_id":"releases","from":41,"to":42}
{"type":"add","group_id":"org.opensaml","artifact_id":"xmltooling","version":"1.4.6","extension":"jar"}
{"type":"checkpoint","cursor":{"index_id":"releases","chain_id":"1234","last_incremental":42,"timestamp":"2026-08-14T10:00:00Z"}}
```

### Database Schema

**repositories**
- Stores Maven repository metadata
- Tracks indexing status, the committed cursor, and statistics
- Has many packages

**maven_artifacts**
- Stores classifier and extension identities from the index
- Supports exact incremental additions and removals

**packages**
- Stores unique packages per repository
- Format: `groupId:artifactId`
- Has many versions

**versions**
- Stores individual package versions
- Tracks release timestamps
- Belongs to a package

## Deployment

A container-based deployment is highly recommended, we use [dokku.com](https://dokku.com/).

### Requirements

- PostgreSQL database
- Redis instance
- Scheduled job runner for Sidekiq periodic tasks (configured via app.json)

### Dokku Deployment

#### Initial Setup

Create the Dokku app:

```bash
dokku apps:create nexus
```

#### Database and Redis

```bash
# Install plugins (if not already installed)
dokku plugin:install https://github.com/dokku/dokku-postgres.git
dokku plugin:install https://github.com/dokku/dokku-redis.git

# Create services
dokku postgres:create nexus-db
dokku redis:create nexus-redis

# Link to app
dokku postgres:link nexus-db nexus
dokku redis:link nexus-redis nexus
```

#### Environment Variables

Set required environment variables:

```bash
dokku config:set nexus RAILS_ENV=production
dokku config:set nexus RAILS_SERVE_STATIC_FILES=true
dokku config:set nexus RAILS_LOG_TO_STDOUT=true
dokku config:set nexus REINDEX_INTERVAL_HOURS=168
```

#### Deploy

```bash
git remote add dokku dokku@your-server:nexus
git push dokku main
dokku ps:scale nexus web=1 worker=1
```

#### Run Migrations

```bash
dokku run nexus bundle exec rake db:migrate
```

#### Scheduled Jobs

Cron jobs are configured in `app.json` and will be automatically set up during deployment:
- `registries:index_all` runs daily at 1 AM

### Environment Setup

1. Set all required environment variables
2. Run database migrations: `bundle exec rake db:migrate`
3. Start web server and Sidekiq workers
4. Configure scheduled jobs (defined in app.json)

### Initial Data

To populate the service with repositories, POST to `/api/v1/sync_repositories` with the repository list from packages.ecosyste.ms:

```bash
curl -X POST http://nexus.ecosyste.ms/api/v1/sync_repositories \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $NEXUS_API_KEY" \
  -d '[
    {"name": "build.shibboleth.net", "url": "https://build.shibboleth.net/nexus/content/repositories/releases"}
  ]'
```

## Monitoring

The application includes:
- `/health` endpoint for uptime monitoring
- `/metrics` endpoint for basic statistics
- Sidekiq web UI at `/sidekiq`
- PgHero at `/pghero` for database monitoring
- AppSignal integration (optional)

## Troubleshooting

### Nexus Command Issues

If the index command cannot start, run `nexus sync -h` in the same environment as the Sidekiq worker and check `NEXUS_BINARY`.

### Index Download Failures

If repository indexing fails:
1. Check the repository URL is correct
2. Verify the repository has a Nexus properties file at `.index/nexus-maven-repository-index.properties`
3. Check the error_message field on the repository record
4. Review Sidekiq logs for detailed error information

### Memory Issues

If you experience memory issues:
1. Reduce Sidekiq concurrency in config/sidekiq.yml
2. Increase REINDEX_INTERVAL_HOURS to reduce frequency
3. Process fewer large repositories simultaneously
4. Check PostgreSQL temporary disk usage during full imports
