#!/bin/bash

set -e

if [ ! -f .admin ]; then
    echo "ERROR: the admin credentials file does not exist."
    echo "If you have not run 'prepare.sh' yet, please do so first."
    echo "If you have already run 'setup.sh', don't run it again."
    exit 1
fi

export $(cat .env | xargs)
export $(cat .admin | xargs)

echo "Setting up the initial Philomena database..."

docker compose pull
docker compose run \
  --rm \
  -e ADMIN_USERNAME=$ADMIN_USERNAME \
  -e ADMIN_EMAIL=$ADMIN_EMAIL \
  -e ADMIN_PASSWORD=$ADMIN_PASSWORD \
  app setup-production

sleep 3

if [ $S3_HOST = "files" ]; then
  echo "Setting up the local S3 storage bucket..."

  docker compose --profile local-storage up -d

  echo "Waiting for Philomena to come online..."

  sleep 15

  if ! docker exec philomena-app-1 philomena eval 'Philomena.Release.create_buckets()'; then
    echo "ERROR: Could not create S3 buckets. Your S3 configuration may be incorrect."
  else
    echo "Successfully created the S3 buckets."
  fi

  docker compose down
fi

rm .admin
