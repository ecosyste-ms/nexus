# [Ecosyste.ms: Nexus](https://nexus.ecosyste.ms)

A Maven repository indexer service that downloads and parses Maven Nexus repository indexes to provide package discovery data to packages.ecosyste.ms.

This project is part of [Ecosyste.ms](https://ecosyste.ms): Tools and open datasets to support, sustain, and secure critical digital infrastructure.

## Overview

Nexus.ecosyste.ms indexes Maven repositories by:
1. Downloading `.index/nexus-maven-repository-index.gz` files from Maven repositories
2. Parsing them using the [maven-index-exporter](https://github.com/ecosyste-ms/maven-index-exporter) Docker container
3. Extracting package names (groupId:artifactId) and versions
4. Providing REST API endpoints for package discovery

## API

### Endpoints

```bash
# Get all packages from a repository
GET /api/v1/repositories/:name/packages

# Get recently updated packages
GET /api/v1/repositories/:name/recent?since=2025-10-29

# Get repository status
GET /api/v1/repositories/:name/status

# Trigger re-index
POST /api/v1/repositories/:name/reindex

# Sync repositories from packages.ecosyste.ms
POST /api/v1/sync_repositories
```

### Example Responses

**GET /api/v1/repositories/build.shibboleth.net/packages**
```json
[
  "org.opensaml:xmltooling",
  "org.opensaml:opensaml-core",
  ...
]
```

**GET /api/v1/repositories/build.shibboleth.net/recent?since=2025-10-29**
```json
[
  {
    "package": "org.opensaml:xmltooling",
    "version": "1.4.6",
    "updated_at": "2025-10-30T12:00:00Z"
  },
  ...
]
```

**GET /api/v1/repositories/build.shibboleth.net/status**
```json
{
  "name": "build.shibboleth.net",
  "last_indexed_at": "2025-10-30T10:00:00Z",
  "package_count": 210,
  "status": "completed"
}
```

## Development

For development and deployment documentation, check out [DEVELOPMENT.md](DEVELOPMENT.md)

## Architecture

- **Rails 8.0** - API-only application
- **PostgreSQL** - Repository, package, and version data storage
- **Redis** - Job queue and caching
- **Sidekiq** - Background job processing
- **Docker** - For running maven-index-exporter

## Models

- **Repository** - Maven repository metadata and indexing status
- **Package** - Maven packages (groupId:artifactId)
- **Version** - Package versions with release information

## Background Jobs

- **IndexRepositoryWorker** - Downloads and processes a single repository index
- **SyncAllRepositoriesWorker** - Processes all repositories (runs daily)
- **CleanupOldIndexesWorker** - Removes old downloaded files

## Contribute

Please do! The source code is hosted at [GitHub](https://github.com/ecosyste-ms/nexus). If you want something, [open an issue](https://github.com/ecosyste-ms/nexus/issues/new) or a pull request.

If you need want to contribute but don't know where to start, take a look at the issues tagged as ["Help Wanted"](https://github.com/ecosyste-ms/nexus/issues?q=is%3Aopen+is%3Aissue+label%3A%22help+wanted%22).

### Note on Patches/Pull Requests

* Fork the project.
* Make your feature addition or bug fix.
* Add tests for it. This is important so we don't break it in a future version unintentionally.
* Send a pull request. Bonus points for topic branches.

### Vulnerability disclosure

We support and encourage security research on Ecosyste.ms under the terms of our [vulnerability disclosure policy](https://github.com/ecosyste-ms/nexus/security/policy).

### Code of Conduct

Please note that this project is released with a [Contributor Code of Conduct](https://github.com/ecosyste-ms/.github/blob/main/CODE_OF_CONDUCT.md). By participating in this project you agree to abide by its terms.

## Copyright

Code is licensed under [GNU Affero License](LICENSE) © 2025 [Andrew Nesbitt](https://github.com/andrew).

Data from the API is licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
