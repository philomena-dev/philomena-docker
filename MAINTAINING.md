# Maintaining this repository

Notes for the people who maintain this repository. Operators of a deployment only need the [README](README.md).

## How deployments follow this repository

A deployment is a clone of this repository, on the branch of its major version of Philomena (`1.x`, `2.x`, ...). `./philomena.sh update` fast-forwards the clone to the tip of that branch, restarts itself from the new scripts, and installs whatever the checkout now points to. Two things follow from that.

**Every commit on a version branch is a release.** Operators can land on it the moment it is pushed. Develop on other branches and merge only what has passed CI.

**A commit must be installable from any earlier commit on the same branch**, without the operator doing anything by hand. Concretely:

- The interface `update` uses to restart itself has to keep working: `./philomena.sh update --no-pull --previous-commit <commit> [options]`, as called by the previous version of `scripts/release.sh`.
- The two ends of the server link can run different commits for a while. Operators update the app server first, then the proxy server. A change to the link has to work with the proxy server still on the previous commit.
- A data directory keeps its place in `./volumes`. A change of layout needs a migration in `update`.

Changes that cannot meet these rules wait for the next major version branch, where the release notes can ask operators to act.

## Releasing a version of Philomena

1. Point the images at the release:

   ```sh
   scripts/dev/bump-philomena.sh 1.3.0
   ```

   The application, web server and media processor images always move together. CI fails if they differ.

2. Check the release's [upgrade contract](#the-upgrade-contract-with-philomena): does the image bring its own release migrations, and do they need anything from the operator?
3. Compare `docker-compose.yml` with what the release expects: new required environment variables in `config/runtime.exs`, the service versions in Philomena's own `docker-compose.yml`, and the routes in `docker/production/web/Caddyfile` that `config/nginx/cdn/storage.conf` mirrors.
4. Push to a development branch and let CI run. The smoke test installs a deployment from scratch, updates it and restores it.
5. Merge into the version branch.

A new major version of Philomena gets a new branch, created from the previous one. The previous branch keeps receiving fixes for as long as that major version is supported.

## Other images

Dependabot proposes updates of the other images every week. Minor and patch updates can be merged once CI passes.

Major versions of PostgreSQL, OpenSearch and Valkey are ignored by Dependabot on purpose. They change the on-disk format, so `update` has to convert the data (for PostgreSQL: a dump and restore, or `pg_upgrade`) before such a version can be pinned, and the version has to be one the Philomena release was tested with. The `backup` service uses the same PostgreSQL image as the database, so that `pg_dump` always matches the server.

OpenResty is pinned to an exact build. `config/nginx/lua/s3.lua` uses `resty.openssl`, which ships with the image.

## Settings

`.env` is written once by `prepare` and belongs to the operator from then on. `git pull` never touches it, so:

- **Give new settings a default** in the Compose files (`${NAME:-default}`) whenever one exists. Existing deployments then keep working untouched.
- **A setting without a possible default** goes into `templates/app.env` or `templates/proxy.env`. `check` reports every setting of the template that a deployment's `.env` lacks, and `update` runs `check` before it changes anything, so operators are told what to add before any downtime.
- **Renaming or restructuring settings** needs a migration: raise `config_version` in `scripts/lib.sh` and add a function `migrate_config_to_<version>` that rewrites `.env` with `env_get` and `env_set`. It runs automatically, after a copy of the old file has been saved.

Wiring that is the same for every deployment (service addresses, URL layout) belongs in the Compose files, not in `.env`.

## The upgrade contract with Philomena

Everything that touches the database is done by the application image. This repository only orchestrates: preflight, backup, stop, upgrade, start.

- `setup-production` creates or upgrades the database and the search indexes. It is safe to run on every deploy.
- `setup-production --preflight` checks, without changing anything, whether the upgrade can go ahead. `update` runs it against the live database before taking the site down, and stops if it fails.
- Steps specific to a release are *release migrations*, in `priv/release-migrations/<version>/` of the Philomena repository: `preflight`, `pre-migrate` and `post-migrate`. `setup-production` runs the ones a database has not seen yet and records them in the `release_migrations` table.
- A release migration that needs a decision from the operator reads it from an environment variable and explains what to set. Operators pass it with `./philomena.sh update -e NAME=value`. This repository does not need to know about any particular variable.

### Images without release migrations

`compat/release-setup` holds a copy of `setup-production` and the release migrations, taken from the Philomena repository with `scripts/dev/sync-release-setup.sh`. `update` and `setup` mount it into images that do not contain `priv/release-migrations` themselves, which is the case up to 1.3.0-rc1.

Once every image this branch can point to has its own, delete `compat/` and the fallback in `run_setup_production`.

### Web server image

`config/caddy/entrypoint.sh` adds `trusted_proxies` to the configuration of `philomena-web` images that lack it (up to 1.3.0-rc1), and does nothing for images that have it. Delete it, and the `entrypoint` of the `caddy` service, once the pinned release includes the setting.

## Testing

```sh
scripts/dev/shellcheck.sh    # needs shellcheck
scripts/dev/smoke-test.sh    # needs Docker and free ports 80 and 443
```

The smoke test covers the single-server layout. Before merging a change to the server link (`docker-compose.link-*.yml`, `config/nginx/link*`, the proxy bundle), test a two-server deployment by hand. Both ends can run on one machine: give the two checkouts different values of `COMPOSE_PROJECT_NAME` in `.env`, and use the address of the Docker host as the address of the other end (`host.docker.internal` on Docker Desktop, the gateway of the bridge network on Linux).

The WireGuard tunnel (`scripts/wireguard.sh`, `scripts/install-wireguard.sh`) belongs to the host, so it cannot be exercised by two checkouts on one machine. Its configuration can be: mount each checkout into a container that has `NET_ADMIN` and `wireguard-tools`, with the two containers on one network, and run `wg-quick up` on `wireguard/philomena.conf` in both.

CI also runs weekly, to catch a pinned image that disappeared and changes to Cloudflare's address ranges (`scripts/dev/update-cloudflare-ips.sh` regenerates the list).
