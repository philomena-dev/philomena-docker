#!/usr/bin/env bash
# This file is meant to be sourced by `philomena.sh`, not executed directly.
# It contains the commands that create and upgrade the database: `setup` and
# `update`.

. scripts/check.sh

# The services that use the database, and have to be stopped while it is
# being changed.
app_services=(app worker scheduler backup)

function infrastructure_services {
  echo postgres opensearch valkey mediaproc

  if uses_local_storage; then
    echo files
  fi
}

# Whether the application image brings its own release migrations (see
# docker/production/setup-production in the Philomena repository).
function image_has_release_migrations {
  compose run --rm --no-deps --entrypoint /bin/sh app \
    -c 'test -d /srv/philomena/priv/release-migrations' > /dev/null 2>&1
}

# Run `setup-production` from the application image, which creates or
# migrates the database and the search indexes.
#
# Arguments up to `--` are options for `docker compose run`, the ones after
# it are passed to the script.
function run_setup_production {
  local run_args=() script_args=()

  while [[ $# -gt 0 && $1 != -- ]]; do
    run_args+=("$1")
    shift
  done

  shift || true
  script_args=("$@")

  # The command is not logged: its options can carry credentials.
  if image_has_release_migrations; then
    compose run --rm ${run_args[@]+"${run_args[@]}"} app \
      setup-production ${script_args[@]+"${script_args[@]}"}
  else
    # Images released before release migrations existed are given the copy
    # kept in this repository.
    compose run --rm ${run_args[@]+"${run_args[@]}"} \
      -v "$repo_root/compat/release-setup:/opt/release-setup:ro" \
      -e RELEASE_MIGRATIONS_DIR=/opt/release-setup/release-migrations \
      app /bin/sh /opt/release-setup/setup-production ${script_args[@]+"${script_args[@]}"}
  fi
}

function start_infrastructure {
  local services
  read -r -a services <<< "$(infrastructure_services | tr '\n' ' ')"

  step compose up -d --wait "${services[@]}"
}

# Bind-mounted configuration is only read when a container starts, so a
# service is restarted when an update of this checkout changed its files.
function restart_configured_services {
  local previous_commit=$1 service paths restart=()

  [[ -n $previous_commit ]] || return 0

  for service in caddy web link tinyproxy opensearch; do
    case "$service" in
      caddy) paths=(config/caddy) ;;
      web | link) paths=(config/nginx) ;;
      tinyproxy) paths=(config/tinyproxy.conf config/tinyproxy-filter) ;;
      opensearch) paths=(config/opensearch.yml) ;;
    esac

    if ! git diff --quiet "$previous_commit" HEAD -- "${paths[@]}" && is_running "$service"; then
      restart+=("$service")
    fi
  done

  if [[ ${#restart[@]} -gt 0 ]]; then
    step compose restart "${restart[@]}"
  fi
}

# Fail early when an image is neither on this server nor being pulled.
function require_images {
  local image

  while IFS= read -r image; do
    docker image inspect "$image" > /dev/null 2>&1 ||
      die "The image $image is not on this server. Run the update without --no-image-pull."
  done < <(compose config --images)
}

function cmd_setup {
  require_config
  has_app || die "There is nothing to set up on a proxy server. Run './philomena.sh up'."

  if [[ ! -f .admin ]]; then
    die "The file with the first administrator account (.admin) does not exist, which means this deployment has been set up before. Use './philomena.sh up' to start it and './philomena.sh update' to upgrade it."
  fi

  cmd_check || exit 1
  acquire_lock

  step compose pull --quiet
  prepare_volumes
  start_infrastructure

  info "Creating the database..."

  if ! run_setup_production \
    -e "ADMIN_USERNAME=$(env_get ADMIN_USERNAME .admin)" \
    -e "ADMIN_EMAIL=$(env_get ADMIN_EMAIL .admin)" \
    -e "ADMIN_PASSWORD=$(env_get ADMIN_PASSWORD .admin)" \
    --; then
    error "The database could not be created."
    error "To start over once the problem is fixed, run './philomena.sh down', remove ./volumes/postgres and ./volumes/opensearch, and run setup again."
    exit 1
  fi

  if uses_local_storage; then
    info "Creating the storage bucket..."
    step compose run --rm app philomena eval 'Philomena.Release.create_buckets()'
  fi

  rm -f .admin

  step compose up -d --remove-orphans --wait

  if [[ $(role) == app ]]; then
    info "The application is running. Next: run './philomena.sh proxy-bundle' and set up the proxy server."
  else
    info "Philomena is running at https://$(env_get SITE_DOMAIN)"
  fi
}

# Bring this checkout up to date, and continue with the new version of the
# scripts if anything changed.
function self_update {
  local target_branch=$1 branch before after
  shift

  if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    warn "This directory is not a git checkout, so it cannot update itself."
    return 0
  fi

  if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
    git status --short --untracked-files=no >&2
    die "Files that belong to this repository were changed. Put local adjustments in $env_file or docker-compose.override.yml, restore these files with 'git checkout -- <file>', and try again. Use --no-pull to update without touching the checkout."
  fi

  branch=$(git symbolic-ref --short -q HEAD) || die "This checkout is not on a branch. Check out the branch of your major version (for example 1.x)."
  before=$(git rev-parse HEAD)

  step git fetch --quiet origin

  if ! git rev-parse --verify --quiet "origin/$branch" > /dev/null; then
    die "The branch '$branch' does not exist in the origin repository."
  fi

  if [[ -n $target_branch && $target_branch != "$branch" ]]; then
    switch_major_version "$branch" "$target_branch"
  else
    step git merge --quiet --ff-only "origin/$branch" ||
      die "This checkout has commits that are not in origin/$branch. Remove them, or use --no-pull."
  fi

  after=$(git rev-parse HEAD)

  if [[ $before != "$after" ]]; then
    info "This checkout was updated ($(git rev-list --count "$before..$after") new commits), continuing with the new version."
    exec ./philomena.sh update --no-pull --previous-commit "$before" "$@"
  fi
}

# Major versions live on branches named `<major>.x`. They can only be
# crossed one at a time, starting from a fully updated deployment.
function switch_major_version {
  local branch=$1 target=$2

  if [[ ! $branch =~ ^([0-9]+)\.x$ ]]; then
    die "The current branch ($branch) is not a major version branch."
  fi

  if [[ $target != "$((BASH_REMATCH[1] + 1)).x" ]]; then
    die "From $branch, the only branch that can be switched to is $((BASH_REMATCH[1] + 1)).x. Major versions cannot be skipped."
  fi

  if ! git rev-parse --verify --quiet "origin/$target" > /dev/null; then
    die "The branch '$target' does not exist in the origin repository."
  fi

  if [[ $(git rev-parse HEAD) != "$(git rev-parse "origin/$branch")" ]]; then
    die "$branch has updates that this deployment does not have yet. Run './philomena.sh update' first, then switch to $target."
  fi

  warn "Switching from $branch to $target. Read the release notes of $target before continuing."
  confirm "Switch to $target?" || exit 1

  if git rev-parse --verify --quiet "$target" > /dev/null; then
    step git checkout --quiet "$target"
    step git merge --quiet --ff-only "origin/$target"
  else
    step git checkout --quiet --track "origin/$target"
  fi
}

# An upgrade can rewrite whole tables, and needs room for a backup. Running
# out of disk space halfway is the one failure that is hard to recover from.
function require_disk_space {
  local database free

  database=$(compose exec -T postgres psql -U philomena -d philomena -tAc \
    "SELECT pg_database_size('philomena') / 1024 / 1024" 2> /dev/null || echo 0)
  free=$(df -Pk . | awk 'NR == 2 { print int($4 / 1024) }')

  if ((free < database)); then
    warn "The database takes up $((database / 1024)) GB, and only $((free / 1024)) GB of disk space is free."
    warn "Upgrading with less free space than the size of the database risks running out halfway."

    # Not something --yes should wave through.
    if [[ ! -t 0 ]]; then
      die "Free up disk space, or run the update from a terminal to decide for yourself."
    fi

    assume_yes=false confirm "Continue anyway?" || exit 1
  fi
}

function image_id_of_container {
  docker inspect --format '{{.Image}}' "$1" 2> /dev/null
}

function image_id_of_service {
  docker image inspect --format '{{.Id}}' "$(service_image "$1")" 2> /dev/null
}

function image_version {
  docker image inspect \
    --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1" 2> /dev/null
}

function cmd_update {
  local pull=true pull_images=true backup=true target_branch='' previous_commit=''
  local setup_env=() passthrough=()
  local container previous_image backup_file

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes | -y)
        assume_yes=true
        passthrough+=("$1")
        ;;
      --no-pull) pull=false ;;
      --no-image-pull)
        pull_images=false
        passthrough+=("$1")
        ;;
      --skip-backup)
        backup=false
        passthrough+=("$1")
        ;;
      --branch)
        target_branch=${2:-}
        [[ -n $target_branch ]] || die "--branch needs the name of a branch."
        shift
        ;;
      --previous-commit)
        previous_commit=${2:-}
        shift
        ;;
      -e)
        [[ ${2:-} == *=* ]] || die "-e needs an argument of the form NAME=value."
        setup_env+=(-e "$2")
        passthrough+=(-e "$2")
        shift
        ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done

  require_config
  require_docker
  acquire_lock

  if [[ $pull == true ]]; then
    require_command git
    self_update "$target_branch" ${passthrough[@]+"${passthrough[@]}"}
  fi

  cmd_check || exit 1

  if [[ $pull_images == true ]]; then
    step compose pull --quiet
  else
    require_images
  fi

  if ! has_app; then
    step compose up -d --remove-orphans --wait
    restart_configured_services "$previous_commit"
    step docker image prune --force > /dev/null
    info "The proxy server is up to date."
    return 0
  fi

  if [[ -f .admin ]]; then
    die "This deployment has not been set up yet. Run './philomena.sh setup'."
  fi

  prepare_volumes

  container=$(container_of app)
  previous_image=$(image_id_of_container "$container" || true)

  if [[ -n $container && $previous_image == "$(image_id_of_service app)" ]]; then
    info "The application image has not changed."
    step compose up -d --remove-orphans --wait
    restart_configured_services "$previous_commit"
    step docker image prune --force > /dev/null
    info "Philomena is up to date ($(image_version "$(service_image app)"))."
    return 0
  fi

  # Everything up to here has left the running site alone. The new release
  # now gets to look at the database, still without changing anything.
  if ! is_running postgres || ! is_running opensearch; then
    start_infrastructure
  fi

  info "Checking whether the database can be upgraded..."

  if ! run_setup_production --no-deps ${setup_env[@]+"${setup_env[@]}"} -- --preflight; then
    error "The new release cannot be installed yet. Nothing was changed, and the site keeps running the previous version."
    error "Deal with what is reported above, then run the update again. Options the release asks for are passed with -e, for example: ./philomena.sh update -e NAME=1"
    exit 1
  fi

  require_disk_space

  if [[ $backup == true ]]; then
    info "Backing up the database..."
    step compose run --rm --no-deps backup once
    backup_file=$(find backups -maxdepth 1 -name 'database_*.pgdump' | sort | tail -n 1)
  fi

  warn "The site will be unavailable while the database is upgraded."
  confirm "Continue?" y || exit 1

  # Present for as long as the database may be partly upgraded. `up` refuses
  # to start the application while it exists.
  date > "$incomplete_marker"

  step compose stop "${app_services[@]}"
  start_infrastructure

  info "Upgrading the database..."

  if ! run_setup_production ${setup_env[@]+"${setup_env[@]}"} --; then
    error "The upgrade failed. The application has been left stopped, because the database may be partly upgraded."
    error "To try again after fixing the problem: ./philomena.sh update --no-pull"

    if [[ -n ${backup_file:-} ]]; then
      error "To go back to the previous version:"
      [[ -z $previous_commit ]] || error "  git reset --hard $previous_commit"
      error "  ./philomena.sh restore $backup_file"
    fi

    exit 1
  fi

  rm -f "$incomplete_marker"

  step compose up -d --remove-orphans --wait
  restart_configured_services "$previous_commit"
  step docker image prune --force > /dev/null

  info "Philomena was updated to $(image_version "$(service_image app)")."
}
