teslamate
=========

Source: https://docs.teslamate.org/docs/installation/docker

Using the simple installation method because the UIs are not exposed to the internet.

Setup the .env and .htpasswd files locally following the instructions in the teslamate docs.

Crontab entry for backups:

```
42 3 * * 0 cd /home/jori/infra-pi-home/teslamate && ./backup-db.sh
```

NOTE: data is stored in Docker volume, not in the infra-pi-home dir.
When you reinstall, be sure to grab a fresh dump first. Otherwise you may lose some data if you go by the dumps on S3.
