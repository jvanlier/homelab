# Home Assistant Ambacht

## What's inside

My Home Assistant configuration files, a `docker-compose.yml` to run it, a backup script for S3, and a custom Dockerfile that bakes in the custom components that I need.

N.b.: in order to make the baked-in custom components work, the config dir contains a (probably) dead symlink `custom_components > /custom_components`.
This is needed because the custom components must in the config dir, but that dir gets mounted during run, so anything we place there at build time will not be visible at run time.
The symlink makes Home Assistant use the baked-in custom components instead.

## To build

```sh
just build
```

## To test

This invokes the the Home Assistant config checker using the Docker image.
It is useful to catch errors as early as possible, i.e. before trying it on the live Home Assistant.
It catches things that the yaml checker in the pre-commit doesn't:

```sh
just test
```

## Backups

Crontab entry for backups:

```
42 4 * * 0 cd /home/jori/infra-pi-home/home-assistant && ./backup.sh
```
