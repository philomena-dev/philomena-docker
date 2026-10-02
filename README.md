# Philomena Docker Deployment

Runs a production [Philomena](https://github.com/philomena-dev/philomena) site with Docker Compose. One script, `philomena.sh`, installs it, keeps it updated, and backs it up.

There are two supported layouts:

| Layout | Servers | Use it when |
| --- | --- | --- |
| **App server + proxy server** (recommended) | Two | The site is open to the public. |
| **Single server** | One | The site is small, private, or being evaluated. |

In the two-server layout, the proxy server is the only machine visitors and third parties ever talk to. It terminates TLS, serves and caches the CDN domain, proxies embedded external images, and makes every outgoing request the scraper needs. The app server holds the database and the application, accepts connections only from the proxy server, and its address does not appear anywhere. If the proxy server comes under attack it can be replaced in minutes, without touching any data.

On a single server the same components run side by side. This works well, but the address of the machine that holds your data is public, and every fetch of a user-submitted URL originates from it.

A single-server deployment can be split into two later without reinstalling: see [Adding a proxy server later](#adding-a-proxy-server-later).

## Requirements

### App server (or single server)

- Any Docker host on x86_64 or arm64; Debian 13 (trixie) is tested
- At least 4 CPU cores
- At least 16 GB RAM
- At least 50 GB of SSD storage
  - 10 GB for the system and container images
  - 10 GB for the database and the search indexes
  - 6 GB for database backups
  - 8 GB for logs
  - On a single server, 8 GB for the CDN cache
  - If uploaded files are kept on this server, 30 GB per 10,000 images
- Outgoing internet access

### Proxy server

- Any Docker host on x86_64 or arm64
- 2 CPU cores, 2 GB RAM
- 20 GB of storage, of which 8 GB is the CDN cache
- Preferably at a different hosting provider than the app server

### Services

- **A domain for the site**, plus a domain for the CDN and one for proxied external images.
  - A CDN domain that is separate from the site's domain keeps the site from being [blocked](https://en.wikipedia.org/wiki/Google_Safe_Browsing) when someone uploads a malicious file. If that does not concern you, subdomains of the site's domain work too (`cdn.example.org`, `ext.example.org`).
  - All three point at the proxy server, or at the single server.
- **An SMTP relay** for account confirmations and password resets. Pick one that does not add the address of the sending client to outgoing mail, or the address of the app server ends up in every message.
- **[hCaptcha](https://www.hcaptcha.com/) keys.**
- **A [Tumblr API key](https://www.tumblr.com/docs/en/api/v2)**, used by the scraper.
- **S3-compatible object storage** for uploaded files, such as Cloudflare R2. Optional: files can be kept on the app server instead.
- **A second bucket at another provider**, such as Backblaze B2, that every upload is copied to. Optional.

## Installation

### 1. Prepare each server

As root, install the required packages and [Docker](https://docs.docker.com/engine/install/debian/):

```sh
apt update
apt install git openssl
docker run --rm hello-world
```

On the app server (or single server), raise a kernel limit the search engine depends on:

```sh
echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-philomena.conf
sysctl --system
```

Create a user for the deployment and let it use Docker:

```sh
adduser philomena
usermod -aG docker philomena
```

Everything from here on is done as that user. Clone this repository:

```sh
git clone https://github.com/philomena-dev/philomena-docker
cd philomena-docker
```

### 2. Set up the app server (or single server)

```sh
./philomena.sh prepare
```

This asks for the layout, the domains, and where uploaded files are kept, and writes the settings to `.env`. It prints the password of the first administrator account; note it down.

Open `.env` and fill in every value that reads `CHANGE_THIS`. The file explains each setting.

<details>
<summary>Object storage with Cloudflare R2 and a second bucket at Backblaze B2</summary>

The credentials below are made up.

```
S3_SCHEME=https
S3_HOST=ea642d6c6561f0f28f43e01b318c57dc.r2.cloudflarestorage.com
S3_PORT=443
S3_REGION=auto
S3_BUCKET=philomena-images-758b544c
AWS_ACCESS_KEY_ID=b0f0dd4fd649c06ec598b80a8e35f186
AWS_SECRET_ACCESS_KEY=dcc5c420d9fa79d74c17361b3e038475f3c6a2a98cae5d80bb73d813f0179aaf

# A token that can only read, for the web servers
WEB_AWS_ACCESS_KEY_ID=7d1f0c9e4f3a4b0f9a2f6c1d6d3e8b52
WEB_AWS_SECRET_ACCESS_KEY=0f6e2a7f9c4b1d3e8a5c7b9d2f4e6a8c0b1d3f5a7c9e2b4d6f8a0c2e4b6d8f1a

ALT_S3_SCHEME=https
ALT_S3_HOST=s3.eu-central-003.backblazeb2.com
ALT_S3_PORT=443
ALT_S3_REGION=eu-central-003
ALT_S3_BUCKET=philomena-backups-bf7afb0f
ALT_AWS_ACCESS_KEY_ID=59050766e380fe0cc501fcf91
ALT_AWS_SECRET_ACCESS_KEY=1291e01247a6f6d30052f86593cc1df
```

</details>

Then verify the server and the settings, and install:

```sh
./philomena.sh check
./philomena.sh setup
```

`setup` creates the database and starts everything. On a single server the site is now reachable; log in and change the administrator password.

> [!IMPORTANT]
> Copy `.env` somewhere safe. It holds the secrets passwords and sessions are derived from. A database backup cannot be used without it.

### 3. Set up the proxy server

Skip this on a single server.

On the app server, package what the proxy server needs to know:

```sh
./philomena.sh proxy-bundle
```

Copy the resulting `proxy-bundle.tar.gz` into the repository on the proxy server, and there run:

```sh
./philomena.sh prepare --proxy proxy-bundle.tar.gz
./philomena.sh check
./philomena.sh up
```

Delete the bundle from both servers afterwards; it contains credentials.

The two servers talk to each other over two ports, both of which only accept a peer holding a certificate from the deployment's private authority:

| Direction | Port | Purpose |
| --- | --- | --- |
| Proxy server → app server | 8443 | Requests for the site |
| App server → proxy server | 3129 | Outgoing requests of the scraper |

Restrict each port to the address of the other server in your hosting provider's firewall. Docker publishes ports in a way that bypasses `ufw` and similar host firewalls, so do not rely on those.

When files are kept in object storage, the proxy server reads them from there directly. When they are kept on the app server, it requests them through the link.

### Certificates

The public-facing server needs a certificate that is valid for all three domains. `prepare` asks for one, and creates a self-signed certificate if you have none yet.

To use [certbot](https://certbot.eff.org/), request the certificate with the webroot method, which works while the site is running, and let certbot install it after every renewal:

```sh
certbot certonly --webroot -w /home/philomena/philomena-docker/volumes/acme \
  -d philomena.example -d philomena-cdn.example -d ext.philomena-cdn.example \
  --deploy-hook '/home/philomena/philomena-docker/philomena.sh cert install /etc/letsencrypt/live/philomena.example'
```

To install a certificate from anywhere else, such as an origin certificate issued by your DDoS protection service, put `fullchain.pem` and `privkey.pem` in a directory and run:

```sh
./philomena.sh cert install /path/to/directory
```

`./philomena.sh check` warns when a certificate is about to expire.

### Behind Cloudflare

If the domains are proxied by Cloudflare or a similar service, the public-facing server has to be told, or it will see every visitor as coming from that service. In `.env` on the proxy server (or single server), set:

```
CLIENT_IP_SOURCE=cloudflare
```

and run `./philomena.sh up`. For other services, see [config/nginx/realip](config/nginx/realip).

## Day-to-day operation

Run `./philomena.sh` without arguments for the full list of commands.

| Command | What it does |
| --- | --- |
| `./philomena.sh status` | Shows what is running, and the age of the newest backup |
| `./philomena.sh logs [service]` | Follows the logs |
| `./philomena.sh up` / `down` | Starts or stops everything |
| `./philomena.sh restart [service]` | Restarts everything, or one service |
| `./philomena.sh psql` | Opens a database console |
| `./philomena.sh console` | Opens an Elixir console in the running application |
| `./philomena.sh check` | Verifies the server, the settings and the certificates |

`docker compose` commands work as usual in this directory.

All services start again on their own after a reboot.

The periodic jobs of the application run in the `scheduler` container: one batch every five minutes, and the daily maintenance at `CRON_DAILY_HOUR` (UTC). Nothing needs to be added to the host's crontab.

### Changing settings

Edit `.env`, then run `./philomena.sh check` and `./philomena.sh up`. Do not edit the files that belong to this repository, as that blocks updates. Changes to the Compose configuration go in a `docker-compose.override.yml`, added to the end of `COMPOSE_FILE` in `.env`.

### Backups

The `backup` container writes a dump of the database to `./backups` every day at `BACKUP_HOUR` (UTC), and removes dumps older than `BACKUP_KEEP_DAYS` days. `./philomena.sh backup` makes one immediately.

Copy these off the server regularly:

- `./backups`
- `.env`
- `./volumes/files`, if uploaded files are kept on the app server
- `./certs/internal`, in a two-server deployment

To replace the database with a backup:

```sh
./philomena.sh restore backups/database_2026_01_31-02-00.pgdump
```

This stops the application, restores the database, rebuilds the search indexes from it, and starts the application again.

To recover on a new server, install as described above, but put the saved `.env` in place instead of running `prepare`, remove the `.admin` file if there is one, copy the backup into `./backups`, and run `restore` instead of `setup`.

## Updating

```sh
./philomena.sh update
```

This updates the checkout of this repository, downloads the images it now points to, and installs them. On the app server it:

1. verifies the settings against what the new version expects;
2. lets the new release check the database, while the site keeps running;
3. backs up the database;
4. stops the application, upgrades the database and the search indexes, and starts the new release.

Nothing is changed if one of the first two steps finds a problem. A release can also ask for a decision before it can be installed, such as how to deal with data that does not fit a new constraint. It explains what it needs, and the answer is passed with `-e`:

```sh
./philomena.sh update -e NAME=value
```

In a two-server deployment, update the app server first, then the proxy server.

If an upgrade fails halfway, the application is left stopped and the command prints how to try again and how to return to the previous version from the backup it made.

### Major versions

Each major version of Philomena has a branch in this repository, named `1.x`, `2.x` and so on. `update` stays on the current branch. To move to the next major version, read its release notes, then run:

```sh
./philomena.sh update --branch 2.x
```

Major versions cannot be skipped. The command refuses unless the deployment is fully updated within its current major version first.

## Adding a proxy server later

A single-server deployment becomes the app server of a two-server deployment as follows.

1. In `.env`, set `ROLE=app` and `COMPOSE_FILE=docker-compose.yml:docker-compose.link-app.yml`, and add:

   ```
   ORIGIN_ADDRESS=<address of this server, as reachable from the proxy server>
   ORIGIN_PORT=8443
   PROXY_SERVER=<address of the proxy server, as reachable from this server>
   SCRAPER_LINK_PORT=3129
   PROXY_HOST=http://link:3128
   ```

2. Run `./philomena.sh cert link` and `./philomena.sh up`.
3. Continue with [Set up the proxy server](#3-set-up-the-proxy-server), then point the DNS records of all three domains at the proxy server.

## Support

Questions about setting up and running a deployment are welcome in [the discussions section](https://github.com/philomena-dev/philomena-docker/discussions).

To report a problem with the files in this repository, or to suggest an improvement, [create an issue](https://github.com/philomena-dev/philomena-docker/issues).
