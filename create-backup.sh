#!/bin/sh
DB_FILENAME=$(date +%Y_%m_%d-%H-%M)

docker exec philomena-postgres-1 pg_dump -U philomena -Fc -O philomena > /home/philomena/philomena-docker/backups/database_${DB_FILENAME}.pgdump
find /home/philomena/philomena-docker/backups -type f -prune -mtime +14 -exec rm -f {} \;
