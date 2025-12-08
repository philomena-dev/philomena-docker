# Philomena Docker-Based Production

> [!WARNING]
> 
> This deployment method is not recommended and only suitable for a limited number of use cases, which are:
> 
> - Very small instances (less than 10,000 images)
> - Budget-constrained instances
> - Short-term instances (intended to run for less than 12 months)
> - To test/evaluate the Philomena software
> 
> **If you intend to run a Philomena instance which does not meet the above criteria, we highly recommend that you follow the [Kubernetes Setup Guide](https://github.com/philomena-dev/philomena/wiki/Production-Setup) instead.**
> 
> Kubernetes deployment is designed with long-term operation and scalability in mind. It has many advantages over the Docker setup, among the most notable of which are easier disaster recovery, better security, and easier long-term maintenance.

> [!CAUTION]
> 
> This deployment method leaves no room for growth. If your site "outgrows" your server hardware, or wish to transition to the Kubernetes-based deployment, you will have to move all of your data to the new server manually, and potentially re-deploy everything from scratch.

### Prerequisites

**Required:**

- One server
   - Any capable Docker host; Debian 13 (trixie) is tested
   - At least 4 CPU cores
   - At least 16 GB RAM
      - More is better, but 16 GB should be sufficient for the use cases outlined above
   - At least 40 GB storage
      - For best results, use SSD storage
      - 8 GB required by CDN cache
      - Reserve at least...
         - 10 GB for system packages and files
         - 10 GB for database and search engine
         - 6 GB for database backups
         - 2 GB for logs
      - Search engine uses 2-4x less storage than the database
      - If you intend to host images locally, provision 30 GB per 10,000 images
   - Internet connection is required
      - ...to pull Docker images
      - ...to communicate with external APIs (hCaptcha, Tumblr)
      - ...to fetch content using the scraper
- SMTP relay/server (for sending mails)
   - You can host it yourself, or opt to use a managed service, but this is outside the scope of this guide
   - This is required for user confirmations and password resets
- [hCaptcha API key](https://www.hcaptcha.com/)
- [Tumblr API key](https://www.tumblr.com/docs/en/api/v2)

**Optional:**

- Two domains
   - One domain for the application (yourapplication.example)
   - One domain for the CDN and a subdomain for the external content service (yourcdnhere.example, ext.yourcdnhere.example)
   - Note on availability:
     - A separate CDN domain protects your application domain from being [globally blocked](https://en.wikipedia.org/wiki/Google_Safe_Browsing) if malicious files are uploaded or proxied through it
     - If this is not relevant to your threat model, you can opt for the CDN and external content services to be subdomains of a single domain (cdn.yourapplication.example, ext.yourapplication.example)
- S3-compatible object storage service (example: Cloudflare R2)
- S3-compatible redundant object storage service for backups (example: Backblaze B2)
- Anti-DDoS proxy service in front of the main site and the CDN domain
   - Such as Cloudflare
   - DDoS protection will help keep your site operational against common denial-of-service vectors
   - Anti-bot features provide some protection against abusive crawlers
- Separate server to run [Go-Camo](https://github.com/cactus/go-camo) and [Tinyproxy](https://github.com/tinyproxy/tinyproxy)
   - For availability considerations, this server **should** be hosted by a different provider than your application server
   - If not used, anti-DDoS proxy services have only minimal effectiveness

### HTTPS/SSL Configuration

Philomena always uses HTTPS in production environment. As such, the webserver needs a SSL certificate. For '.local' domains, the certificate can be generated via 'generate-certificate.sh' script. The generation script is ran as part of 'prepare.sh' if you opt to use a self-signed certificate, so you don't need to run it manually during the initial setup. Please note that you will have to trust the certificate in your browser in that case.

If using a proper domain name, make sure to provide your own SSL certificate and its private key. We recommend using [certbot](https://certbot.eff.org/) to manage certificates for you. You will be asked for a full path to the SSL certificates folder (typically `/etc/letsencrypt/live/yourdomain`). Make sure your SSL certificate includes:

- The app domain (e.g. philomena.example)
- The CDN domain (e.g. philomena-cdn.example)
- The external media domain (e.g. ext.philomena-cdn.example)

Use your actual domains instead of `philomena.example` and `philomena-cdn.example`. When the certificate renews, you will have to run 'copy-certificate.sh' script to copy it to the 'certs' folder. You can setup certbot to run a renew hook which calls the script automatically upon renewal.

If your domain is behind an anti-DDoS proxy like Cloudflare, you might be able to have that service issue an "origin certificate". Copy the origin certificate and its key to the "certs" folder, make sure the certificate is named 'fullchain.pem', and its key is named 'privkey.pem'.

### Installation

> [!NOTE]
> 
> This guide assumes you have correctly configured the domain DNS records to point at your server(s).

First, install the prerequisite packages on your server. As root, run:

```sh
apt update
apt install bash git gettext-base openssl
```

Install Docker by following [this guide](https://docs.docker.com/engine/install/debian/). Test if Docker is available:

```sh
docker run --rm hello-world
```

Create a separate user for Philomena. This is important, as the scripts assume that the location of the repository is `/home/philomena/philomena-docker`.

```sh
adduser philomena
```

In order to allow the philomena account to run Docker, add it to the "docker" user group like so:

```sh
usermod -aG docker philomena
```

As `philomena` user, clone the deployment repository to the `/home/philomena` folder:

```sh
git clone https://github.com/philomena-dev/philomena-docker
cd philomena-docker
```

Run

```sh
./prepare.sh
```

and fill out the prompts. This will automatically generate and fill out the `.env` and `.env-web` files with secret keys and your site domain. The script will also show you the automatically-generated default administrator account password. Make sure to copy it somewhere safe, you will need these credentials to log into your Philomena instance for the first time. You can also find the credentials in the `.admin` file, which will be automatically deleted after the setup is complete.

After you've saved the administrator credentials somewhere safe, open `.env` and `.env-web` with a text editor (such as nano or vim) and fill out any and all variables set to `CHANGE_THIS`.

> [!NOTE]
> 
> Once filled out, make sure to back up the `.env` files somewhere safe. They contain encryption secrets required for Philomena operation. If you lose this file, your users will be forced to reset their passwords before they can log in, and the names of anonymous users will be changed to new random values.

<details>
<summary>Example S3 configuration with Cloudflare R2 and Backblaze B2</summary>

Note: the credentials below are randomly-generated for demonstration purposes only

```
S3_ENDPOINT=https://ea642d6c6561f0f28f43e01b318c57dc.r2.cloudflarestorage.com

S3_REGION=auto
S3_SCHEME=https
S3_HOST=ea642d6c6561f0f28f43e01b318c57dc.r2.cloudflarestorage.com
S3_PORT=443
S3_BUCKET=philomena-images-758b544c
AWS_ACCESS_KEY_ID=b0f0dd4fd649c06ec598b80a8e35f186
AWS_SECRET_ACCESS_KEY=dcc5c420d9fa79d74c17361b3e038475f3c6a2a98cae5d80bb73d813f0179aaf

ALT_S3_REGION=
ALT_S3_SCHEME=https
ALT_S3_HOST=s3.eu-central-003.backblazeb2.com
ALT_S3_PORT=443
ALT_S3_BUCKET=philomena-backups-bf7afb0f
ALT_AWS_ACCESS_KEY_ID=59050766e380fe0cc501fcf91
ALT_AWS_SECRET_ACCESS_KEY=1291e01247a6f6d30052f86593cc1df
```
</details>

<details>
<summary>Example S3 configuration with Cloudflare R2 without redundant backups</summary>

Note: the credentials below are randomly-generated for demonstration purposes only

**Remove the ALT_* variables from the .env file.**

```
S3_ENDPOINT=https://ea642d6c6561f0f28f43e01b318c57dc.r2.cloudflarestorage.com

S3_REGION=auto
S3_SCHEME=https
S3_HOST=ea642d6c6561f0f28f43e01b318c57dc.r2.cloudflarestorage.com
S3_PORT=443
S3_BUCKET=philomena-images-758b544c
AWS_ACCESS_KEY_ID=b0f0dd4fd649c06ec598b80a8e35f186
AWS_SECRET_ACCESS_KEY=dcc5c420d9fa79d74c17361b3e038475f3c6a2a98cae5d80bb73d813f0179aaf
```
</details>

<details>
<summary>If using local S3 storage</summary>

**Make sure to remove all ALT_* variables, as well as S3_REGION!**

```
S3_ENDPOINT=http://files:80

S3_SCHEME=http
S3_HOST=files
S3_PORT=80
S3_BUCKET=philomena
AWS_ACCESS_KEY_ID=local-identity
AWS_SECRET_ACCESS_KEY=local-credential
```
</details>

<details>
<summary>If hosting `go-camo` and `tinyproxy` on a separate server:</summary>

Edit the following environment variable

```
PROXY_HOST=http://tinyproxy:3128
```

and replace "tinyproxy" with the IP address of your proxy server. Point whichever domain is set in `CAMO_HOST` to the IP of your proxy server.
</details>

**After filling out the environment files:**

Run

```sh
./check.sh
```

to check whether your configuration is fully filled in. If you see any errors, correct them before proceeding.

### Setting up cron jobs

Philomena relies on periodic cron tasks to be executed on a fixed schedule. To edit your cron file, use

```sh
crontab -e
```

and make sure its contents look similar to this:

```
*/5 * * * * docker exec philomena-app-1 run-cron
0 8 * * * docker exec philomena-app-1 run-cron-daily
```

This will run the cron jobs every 5 minutes, and perform the daily cron tasks at 8 AM every day. Feel free to adjust the exact hour when the daily task is ran, it should be set to a period of reduced user activity.

### Setting up backups

This repository provides a utility script to back up your Philomena instance's database. The backups are stored in the "backups" folder and are created using `pg_dump` with the "custom" dump format. To set the backups to run on a fixed schedule, add this to your cron:

```
0 2 * * * /home/philomena/philomena-docker/scripts/create-backup.sh
```

This will create a backup at 2 AM. Feel free to adjust the exact schedule of this task as needed.

### Running

> [!NOTE]
> 
> You might have to use the command `docker-compose` instead of `docker compose` on some distributions.

Before the first startup, run

```sh
./setup.sh
```

and note if there are any errors in the output. If there are no errors, your Philomena instance is now ready to launch, simply run

```sh
# Read the profile documentation below for instructions on how to
# start Philomena with local S3 storage or local proxy services.
docker compose up -d
```

and access the site via the URL you configured.

**If you wish to enable optional features, add `--profile` argument to the `docker compose up` command.**

Profile | Description
--- | ---
--profile local-storage | Enables local S3 storage (store images on the local server as opposed to external object storage service)
--profile local-proxy | Enables `go-camo` and `tinyproxy` services, if using this option, edit the generated `nginx.conf` file and uncomment the `server` block at the bottom of it

Example:

```sh
docker compose --profile local-storage up -d
docker compose --profile local-storage --profile local-proxy up -d
```

Once Philomena is running, you can log in using the Administrator credentials. They were shown to you upon completion of `prepare.sh` script.

> [!WARNING]
> 
> **Make sure to change the administrator account password after logging in!**

### Maintaining

You can use the provided `philomena.sh` script to access various aspects of the deployment. Philomena must be running for this script to work.

**psql**

```sh
./philomena.sh psql
```

**Elixir console (iex)**

```sh
./philomena.sh console
```

### Updating

To update Philomena to the latest version within the current major revision, run the following:

```sh
docker compose down
git pull
./upgrade.sh
docker compose run app setup-production

# Make sure to include any --profile arguments here, depending on your setup.
docker compose up -d
```

To update to the next major revision, first perform the update as described above, then run the following:

```sh
docker compose down

# Assuming you are on 1.x branch and 2.x branch exists.
# Do not jump between more than 1 major version (e.g. 1.x to 3.x),
# as this is not supported and may result in data corruption and
# failure to update.
git checkout --track origin/2.x
./upgrade.sh
docker compose run app setup-production

# Make sure to include any --profile arguments here, depending on your setup.
docker compose up -d
```

## Support

We're happy to answer any of your questions and help you get your deployment up and running. If you need help setting up production Philomena, or migrating it to our "kubernetes deployment", feel free to ask in [the discussions section](https://github.com/philomena-dev/philomena-docker/discussions).

If you'd like to report an issue with the configuration files provided in this repository, or suggest any improvements, feel free to [create an issue](https://github.com/philomena-dev/philomena-docker/issues).
