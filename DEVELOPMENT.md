# Development

## Setup

First things first, you'll need to fork and clone the repository to your local machine.

`git clone https://github.com/ecosyste-ms/nexus.git`

The project uses Ruby on Rails which have a number of system dependencies you'll need to install.

- [ruby 3.4.7](https://www.ruby-lang.org/en/documentation/installation/)
- [postgresql 14](https://www.postgresql.org/download/)
- [redis 6+](https://redis.io/download/)
- [Docker](https://docs.docker.com/get-docker/) (for [maven-index-exporter](https://github.com/ecosyste-ms/maven-index-exporter))

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

Alternatively you can use the existing docker configuration files to run the app in a container.

Run this command from the root directory of the project to start the service.

```bash
docker-compose up --build
```

You can then load up [http://localhost:3000/health](http://localhost:3000/health) to verify the service is running.

For access the rails console use the following command:

```bash
docker-compose exec app rails console
```

Running rake tasks in docker follows a similar pattern:

```bash
docker-compose exec app rake db:seed
```

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

**External Services:**
- `PACKAGES_ECOSYSTE_MS_URL` - Base URL for packages.ecosyste.ms API
- `PACKAGES_ECOSYSTE_MS_API_KEY` - API key for authentication

**Configuration:**
- `INDEX_RETENTION_DAYS` - How long to keep downloaded indexes (default: 7)
- `REINDEX_INTERVAL_HOURS` - How often to re-index repositories (default: 24)
- `DOCKER_ENABLED` - Whether to use Docker for parsing (default: true)
- `KEEP_INDEX_FILES` - Whether to keep index files after processing (default: false)

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
- Downloads the index, parses it with Docker, and saves packages/versions
- Triggered manually via API or by SyncAllRepositoriesWorker

**SyncAllRepositoriesWorker**
- Runs daily (configured in config/sidekiq.yml)
- Queues IndexRepositoryWorker for all repositories that need reindexing
- A repository needs reindexing if it has never been indexed or was last indexed more than REINDEX_INTERVAL_HOURS ago

**CleanupOldIndexesWorker**
- Runs daily at 2 AM
- Removes downloaded index files older than INDEX_RETENTION_DAYS

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

1. **Download**: Download `.index/nexus-maven-repository-index.gz` from repository
2. **Export**: Run Docker container `ghcr.io/ecosyste-ms/maven-index-exporter` to convert to .fld format
3. **Parse**: Parse .fld file to extract package and version data
4. **Save**: Store packages and versions in PostgreSQL
5. **Cleanup**: Remove temporary files after processing (respects INDEX_RETENTION_DAYS)

### File Format

The .fld file format contains documents with fields:

```
doc 0
  field 0
    name u
    type string
    value org.opensaml|xmltooling|1.4.6|NA|jar
  field 1
    name m
    type string
    value 1761808009306
```

The `u` field contains: `groupId|artifactId|version|classifier|packaging`

### Database Schema

**repositories**
- Stores Maven repository metadata
- Tracks indexing status and statistics
- Has many packages

**packages**
- Stores unique packages per repository
- Format: `groupId:artifactId`
- Has many versions

**versions**
- Stores individual package versions
- Tracks release timestamps
- Belongs to a package

## Development Without Docker

For local development without Docker installed, set `DOCKER_ENABLED=false` in your `.env.development` file. This will skip the Docker export step and allow you to test the application without the maven-index-exporter container.

## Deployment

A container-based deployment is highly recommended, we use [dokku.com](https://dokku.com/).

### Requirements

- PostgreSQL database
- Redis instance
- Docker socket access (for maven-index-exporter)
- Scheduled job runner for Sidekiq periodic tasks

### Environment Setup

1. Set all required environment variables
2. Run database migrations: `bundle exec rake db:migrate`
3. Start web server and Sidekiq workers
4. Configure scheduled jobs (SyncAllRepositoriesWorker, CleanupOldIndexesWorker)

### Initial Data

To populate the service with repositories, POST to `/api/v1/sync_repositories` with the repository list from packages.ecosyste.ms:

```bash
curl -X POST http://nexus.ecosyste.ms/api/v1/sync_repositories \
  -H "Content-Type: application/json" \
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

### Docker Issues

If you encounter Docker-related errors:
1. Verify Docker is installed and running: `docker --version`
2. Check Docker socket permissions
3. Test the maven-index-exporter manually:
   ```bash
   docker run -v /tmp/work:/work ghcr.io/ecosyste-ms/maven-index-exporter
   ```

### Index Download Failures

If repository indexing fails:
1. Check the repository URL is correct
2. Verify the repository has a Nexus index at `.index/nexus-maven-repository-index.gz`
3. Check the error_message field on the repository record
4. Review Sidekiq logs for detailed error information

### Memory Issues

If you experience memory issues:
1. Reduce Sidekiq concurrency in config/sidekiq.yml
2. Increase REINDEX_INTERVAL_HOURS to reduce frequency
3. Lower INDEX_RETENTION_DAYS to clean up files more frequently
4. Consider processing fewer repositories simultaneously
