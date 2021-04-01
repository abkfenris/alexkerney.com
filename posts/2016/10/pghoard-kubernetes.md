<!-- 
.. title: Avoiding Hazards with Postgres on Kubernetes
.. slug: pghoard-kubernetes
.. date: 2016-10-20 23:55:37 UTC
.. tags: pghoard, kubernetes, postgres
.. category: 
.. link: 
.. description: 
.. type: text
.. nocomments: True
-->

Running a database right now on Kubernetes can be a bit hazardous. In the future this will be made better by [PetSets](http://kubernetes.io/docs/user-guide/petset/), but even then we are still going to have to worry about backing up and restoring databases every once in a while.

<!-- TEASER_END -->

__Edit: There's a better way now using [Patroni](https://patroni.readthedocs.io). I'll write that up soon.__

I decided to play with using [PGHoard](https://github.com/ohmu/pghoard) with [Init Containers](http://kubernetes.io/docs/user-guide/production-pods/#handling-initialization) to restore, and a helper container in the same pod to backup. 
PGHoard is nice as it supports a wide variety of cloud providers for backup targets, and it doesn't require you to use S3 compatibility mode for all of them.

## Configs

To start I made the config that I wanted to run PGHoard with and saved that into a ConfigMap.

```yaml
apiVersion: v1
data:
  pghoard.json: |
    {
      "backup_location": "/tmp",
      "backup_sites": {
        "default": {
          "active_backup_mode": "pg_receivexlog",
          "pg_data_directory": "/var/lib/postgresql/data/pgdata",
          "nodes": [
            {
              "host": "127.0.0.1",
              "password": "hoard_pass",
              "port": "5432",
              "user": "pghoard"
            }
          ],
          "object_storage": {
            "storage_type": "google",
            "project_id": "alex-kerney",
            "bucket_name": "pghoard-test",
            "credential_file": "/google_key/pghoard-test"
          }
        }
      }
    }
kind: ConfigMap
metadata:
  creationTimestamp: null
  name: pghoard-config
```

Here I am using [Google Cloud Storage](https://cloud.google.com/storage/archival/) as my storage service with a bucket named `pghoard-test` and associated Google Cloud credential file. As this will run in the same pod as my Postgres container, it should be set to connect to localhost. We will mount this config into our init container and our backup container.

Seeing that we've specified that we have a Google credential file, let's make a secret for it. This is for when your key file is named `pghoard-test` and it is sitting in your local directory `google_key`.

```bash
> kubectl create secret generic pghoard-google --from-file=google_key
```

## Deployment

Now time to pull out the big guns and create our Deployment.

```yaml
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
    name: pghoard-test
    labels:
        service: pghoard
spec:
    replicas: 1
    template:
        metadata:
            name: pghoard-test
            labels:
                service: pghoard
            annotations:
                pod.beta.kubernetes.io/init-containers: '[
                    {
                        "name": "restore",
                        "image": "abkfenris/postgis-pghoard:9.5-1.4.0"
                        "command": ["/bin/sh", "-c"], 
                        "args": ["gosu postgres pghoard_restore get-basebackup --config /pghoard/pghoard.json --target-dir /var/lib/postgresql/data/pgdata --restore-to-master; sleep 1"],
                        "volumeMounts": [
                            {
                                "name": "pg-data",
                                "mountPath": "/var/lib/postgresql/data/"
                            },
                            {
                                "name": "google-key",
                                "mountPath": "/google_key",
                                "readOnly": true
                            },
                            {
                                "name": "pghoard-config",
                                "mountPath": "/pghoard",
                                "readOnly": true
                            }
                        ]
                    }
                ]'
        spec:
            volumes:
                - name: pg-data
                  emptyDir: {}
                - name: google-key
                  secret: 
                    secretName: pghoard-google
                - name: pghoard-config
                  configMap:
                    name: pghoard-config
                - name: postgres-home
                  emptyDir: {}
            containers:
                - image: "abkfenris/postgis-pghoard:9.5-1.4.0"
                  name: postgres
                  lifecycle:
                  	preStop:
                  		exec:
                  			command: ["/bin/sh", "-c", "gosu postgres psql -c 'SELECT pg_switch_xlog();' && gosu postgres pg_ctl -d /var/lib/postgresql/data/pgdata -m fast -w stop"]

                  volumeMounts:
                  - mountPath: "/var/lib/postgresql/data/"
                    name: pg-data
                  env:
                  - name: PGDATA
                    value: "/var/lib/postgresql/data/pgdata"
                  - name: PGHOARD_USER
                  	value: pghoard
                  - name: PGHOARD_PASS
                  	value: hoard_pass
                - image: "abkfenris/postgis-pghoard:9.5-1.4.0"
                  name: backup
                  volumeMounts:
                  - name: google-key
                    mountPath: /google_key
                  - name: pghoard-config
                    mountPath: /pghoard
                  - name: pg-data
                    mountPath: "/var/lib/postgresql/data/"
                  - name: postgres-home
                    mountPath: /home/postgres/
                  command: ['gosu', 'postgres', 'pghoard', '--config', '/pghoard/pghoard.json']

```

Ok, lets break this down.

First we will have our usual Deployment preamble of API version, kind, name, metadata, labels.

```yaml
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
    name: pghoard-test
    labels:
        service: pghoard
```

### Init Container

Then we get into a section of metadata that isn't as common, annotations. Here is where we are going to store our Init Container info in the key `pod.beta.kubernetes.io/init-containers` as a string of JSON.

```yaml
            annotations:
                pod.beta.kubernetes.io/init-containers: '[
                    {
                        "name": "restore",
                        "image": "abkfenris/postgis-pghoard:9.5-1.4.0"
                        "command": ["/bin/sh", "-c"], 
                        "args": ["gosu postgres pghoard_restore get-basebackup --config /pghoard/pghoard.json --target-dir /var/lib/postgresql/data/pgdata --restore-to-master; sleep 1"],
                        "volumeMounts": [
                            {
                                "name": "pg-data",
                                "mountPath": "/var/lib/postgresql/data/"
                            },
                            {
                                "name": "google-key",
                                "mountPath": "/google_key",
                                "readOnly": true
                            },
                            {
                                "name": "pghoard-config",
                                "mountPath": "/pghoard",
                                "readOnly": true
                            }
                        ]
                    }
                ]'
```

While init containers are in a list, just like normal containers in a pod, they are executed sequentially, instead of being run at the same time. Here I'm using the image `abkfenris/postgis-pghoard` tag `9.5-1.4.0`. 

Then I give PGHoard it's commands to run. 

- We start with the command `/bin/sh -c` so that we can string together multiple commands as arguments. Kubernetes doesn't natively understand all of the normal shell keys to combine commands on its own.
- First we use `gosu` to work as the `postgres` user as the data needs to be accessible to the postgres server. 
- The `pghoard_restore` command is going to get the most recent basebackup of the server to rebuild the server directory. 
- `--config` is our PGHoard JSON that we stored in a configmap.
- `--target-dir` unsuprisingly points to where we are storing our postgres data. Postgres doesn't like for it's data folder to be the one that Docker or Kubernetes is directly mounting [(see PGDATA which we will set later)](https://hub.docker.com/_/postgres/).
- `--restore-to-master` If we don't set this it will bring up our system as a standby.
- After our restore command, we follow it with `sleep 1`. Using `;` means that `sleep` will run no matter what `pghoard_restore` exits with. This way if there is an error it won't cause Kubernetes to crash the pod, and instead it can progress to the usual Postgres initialization. There is probably a better way of doing this without catching all errors, and only continuing when there is no base-backup available, and not when other errors occur.

### Volumes

We have a handful of volume mounts here, so let's look at that section of our `spec`.

```yaml
				volumes:
                - name: pg-data
                  emptyDir: {}
                - name: google-key
                  secret: 
                    secretName: pghoard-google
                - name: pghoard-config
                  configMap:
                    name: pghoard-config
                - name: postgres-home
                  emptyDir: {}
```

Init containers will pull volume information from the regular spec.

- `pg-data` is going to be an on-host empty directory. This allows it to be changed by any container in the pod, and last for the life of the pod, but as soon as the pod goes away, so does `pg-data`.
- `google-key` is our credentials for Google that we are pulling from the secret we created earlier.
- `pghoard-config` contains our PGHoard JSON file that we created as a ConfigMap.
- Finally we have `postgres-home` as PGHoard likes to store some temporary files in the home directory of whatever user it is running as.

I'm mounting both the ConfigMap and Secret at the root level, it's only the `pg-data` directory that is being mounted elsewhere. In both the init container and our later serving container, we are mounting it at `/var/lib/postgresql/data/` but storing the data one level deeper in `/var/lib/postgresql/data/pgdata/` so that Postgres can have all the control it wants.

### What happens in a restore?

When the `restore` init container runs, it will first find the available base-backups, then download it to the target-directory.

```bash
Found 2 applicable basebackups

Basebackup                                Backup size    Orig size  Start time
----------------------------------------  -----------  -----------  --------------------
default/basebackup/2016-07-11_0                  7 MB        36 MB  2016-07-11T01:06:53Z
    metadata: {'compression-algorithm': 'snappy', 'compression-level': '0', 'pg-version': '90503', 'start-wal-segment': '000000010000000000000003'}
default/basebackup/2016-10-20_0                  7 MB        36 MB  2016-10-20T23:33:23Z
    metadata: {'compression-algorithm': 'snappy', 'compression-level': '0', 'pg-version': '90504', 'start-wal-segment': '000000030000000000000006'}

Selecting 'default/basebackup/2016-10-20_0' for restore
Download progress: 100.00%
Basebackup restoration complete.
You can start PostgreSQL by running pg_ctl -D /var/lib/postgresql/data/pgdata start
On systemd based systems you can run systemctl start postgresql
On SYSV Init based systems you can run /etc/init.d/postgresql start
```

### First time? Let's get you settled in.

What happens when there are no base-backups available? `pghoard_restore` errors, but then the error is squelched by `sleep 1` and the regular containers in the pod are allowed to boot. 

When `postgres` boots and doesn't find a valid database, it will setup a new database in the specified `PGDATA` directory. Along the way it will run any shell or sql files in `/docker-entrypoint-initdb.d/`. In there there is a file that helps [configure our new database](https://github.com/ohmu/pghoard#setup) to be connected to by PGHoard.

A few changes need to occur to `postgresql.conf`.

```
wal_level = archive
max_wal_senders = 4
archive_timeout = 300
```
While PGHoard can be used with Postgres' archive command, it can also control it's own destiny, and connect to Postgres itself. It needs at least 2 WAL senders available to do so. We also are setting our timeout time, so we don't wait for our WAL files to reach full size, so that our data gets backed up at least every 5 minutes.

The other changed file is `pg_hba.conf` to allow the `PGHOARD_USER` to connect.

```
host replication '$PGHOARD_USER' '127.0.0.1/32' md5
```

Finally our startup script adds the `PGHOARD_USER` and gives it the privilege to replicate data.

```sql
CREATE USER "$PGHOARD_USER" WITH PASSWORD '$PGHOARD_PASS' REPLICATION;
```

Thankfully as long as you've got `PGHOARD_USER` and `PGHOARD_PASS` defined (and they match the JSON config), then none of that should really matter.

### Postgres

Now at this point our `postgres` container looks rather simple. We are just pulling the same image contains both Postgres and PGHoard, mounting the volume, and setting an environment variable to tell Postgres where to store it's data, as we wish it to be one level deeper than normal. 

```yaml
				containers:
                - image: "abkfenris/postgis-pghoard:9.5-1.4.0"
                  name: postgres
                  lifecycle:
                  	preStop:
                  		exec:
                  			command: ["/bin/sh", "-c", "gosu postgres psql -c 'SELECT pg_switch_xlog();' && gosu postgres pg_ctl -d /var/lib/postgresql/data/pgdata -m fast -w stop"]
                  volumeMounts:
                  - mountPath: "/var/lib/postgresql/data/"
                    name: pg-data
                  env:
                  - name: PGDATA
                    value: "/var/lib/postgresql/data/pgdata"
                  - name: PGHOARD_USER
                  	value: pghoard
                  - name: PGHOARD_PASS
                  	value: hoard_pass
```

#### Restoring WAL

While it's tempting to use the standard Docker Postgres image as our server, it isn't quite enough. When the init container finishes, it will have restored a full base-backup (basically a compressed version of the almost entire PGDATA directory), but none of the [Write Ahead Log](https://www.postgresql.org/docs/current/static/wal.html) will be included. The Write Ahead Log is important as it gives us the changes since the base-backup was taken. The Write Ahead Log (WAL) allows the changes to be replayed. 

PGHoard adds a recovery.conf to the PGDATA directory that specifies an `archive_command` to load WAL chunks from the PGHoard server which we will run in another container. Postgres will run the `restore_command` until PGHoard signals that there are no more WAL files to download and replay. Then if the server is again in a consistent state, then it will start.

That will look a lot like:

```bash
LOG:  database system was interrupted; last known up at 2016-10-20 23:33:23 UTC
FATAL:  the database system is starting up
/usr/local/bin/pghoard_postgres_command: ERROR: '00000004.history' not found from archive
LOG:  starting archive recovery
/usr/local/bin/pghoard_postgres_command: ERROR: '00000003.history' not found from archive
LOG:  restored log file "000000030000000000000006" from archive
LOG:  redo starts at 0/6000098
LOG:  consistent recovery state reached at 0/60000C0
LOG:  restored log file "000000030000000000000007" from archive
LOG:  record with incorrect prev-link 0/6000108 at 0/7000028
LOG:  redo done at 0/60000C0
LOG:  restored log file "000000030000000000000006" from archive
/usr/local/bin/pghoard_postgres_command: ERROR: '00000004.history' not found from archive
LOG:  selected new timeline ID: 4
FATAL:  the database system is starting up
/usr/local/bin/pghoard_postgres_command: ERROR: '00000003.history' not found from archive
LOG:  archive recovery complete
LOG:  MultiXact member wraparound protections are now enabled
LOG:  database system is ready to accept connections
LOG:  autovacuum launcher started
```

Notice there aren't any ports exposed, which you will probably need for the application you are working with.

#### Hooking in

We are also adding a lifecycle hook command on pod shutdown. `command: ["/bin/sh", "-c", "gosu postgres psql -c 'SELECT pg_switch_xlog();' && gosu postgres pg_ctl -d /var/lib/postgresql/data/pgdata -m fast -w stop"]` This command immediately creates a new WAL file, allowing PGHoard to start backing up. Then it tries to cleanly, but quickly shutdown the server. Upon server shutdown it generates a final WAL segment.

### PGHoard

The final part is our backup container.

```yaml
                - image: "abkfenris/postgis-pghoard:9.5-1.4.0"
                  name: backup
                  volumeMounts:
                  - name: google-key
                    mountPath: /google_key
                  - name: pghoard-config
                    mountPath: /pghoard
                  - name: pg-data
                    mountPath: "/var/lib/postgresql/data/"
                  - name: postgres-home
                    mountPath: /home/postgres/
                  command: ['gosu', 'postgres', 'pghoard', '--config', '/pghoard/pghoard.json']
```

Our `backup` container will run at the same time, in the same instruction space, and same mounted directories as our `postgres` server container as they share a pod.

Again we mount the same volumes as our init container, but we are additionally mounting the home directory for the `postgres` user. Here we launch the base `pghoard` command as the `postgres` user. 

#### Recover and start backing up

With the config we defined earlier it will try to connect to the server to try to pull backups, and be available at 16000 to serve WAL files as the server recovers.

```bash
2016-10-20 23:44:55,747	TransferAgent	Thread-9	WARNING	'default/timeline/00000006.history' not found from storage
2016-10-20 23:44:55,748	TransferAgent	Thread-9	INFO	'DOWNLOAD' FAILED transfer of key: 'default/timeline/00000006.history', size: 0, took 0.409s
	INFO	'DOWNLOAD' transfer of key: 'default/xlog/000000030000000000000006', size: 797320, took 0.212s
2016-10-20 23:44:56,759	TransferAgent	Thread-11	INFO	'DOWNLOAD' transfer of key: 'default/xlog/00000003000000000000000A', size: 797297, took 0.249s
2016-10-20 23:44:56,792	TransferAgent	Thread-8	INFO	'DOWNLOAD' transfer of key: 'default/xlog/000000030000000000000008', size: 797296, took 0.284s
2016-10-20 23:44:56,820	TransferAgent	Thread-10	INFO	'DOWNLOAD' transfer of key: 'default/xlog/000000030000000000000009', size: 797297, took 0.311s
2016-10-20 23:44:57,076	TransferAgent	Thread-12	INFO	'DOWNLOAD' transfer of key: 'default/xlog/000000030000000000000007', size: 797296, took 0.568s
127.0.0.1 - - [20/Oct/2016 23:44:57] "GET /default/archive/000000030000000000000006 HTTP/1.1" 201 -
127.0.0.1 - - [20/Oct/2016 23:44:58] "GET /default/archive/000000030000000000000007 HTTP/1.1" 201 -
2016-10-20 23:44:59,081	TransferAgent	Thread-11	INFO	'DOWNLOAD' transfer of key: 'default/xlog/000000030000000000000006', size: 797320, took 0.359s
2016-10-20 23:44:59,108	TransferAgent	Thread-9	INFO	'DOWNLOAD' transfer of key: 'default/xlog/000000030000000000000007', size: 797296, took 0.386s
127.0.0.1 - - [20/Oct/2016 23:44:59] "GET /default/archive/000000030000000000000006 HTTP/1.1" 201 -
2016-10-20 23:44:59,970	TransferAgent	Thread-12	WARNING	'default/timeline/00000004.history' not found from storage
...
```
In addition to the WAL files found in default/xlog there are often warnings about .history files. From what I've seen it's they aren't going to cause everything to fall apart. The big issue is is there are WAL segments missing.

## Conclusion

There are a few more things that you might want to think about before deploying it. What `PG_USER` and `PG_PASS` values you wish to use. [`pg_isready`](https://www.postgresql.org/docs/current/static/app-pg-isready.html) for a readiness probe.

This isn't quite a high availability deployment yet. Tools like [stolon](https://github.com/sorintlab/stolon) and [Patroni](https://github.com/zalando/patroni) will be ready to go soon. [pglogical](https://2ndquadrant.com/en/resources/pglogical/) and [Postgres-BDR](https://2ndquadrant.com/en/resources/bdr/) are both also under development.

You can find the Dockerfiles for my blend of PostgreSQL, PostGIS, and PGHoard on [Github](https://github.com/abkfenris/docker-postgis-pghoard).

## Update - Getting things into a container

If you've gone and `pg_dump`ed out an existing database, and you want to use `psql` to restore it into your newly setup and backing up databese, then you can use `kubectl exec postgres-pghoard-pod -c postgres -i -- /bin/bash -c 'gosu postgres psql' < dump.sql` to get your local `dump.sql` in there.

You also could use `kubectl port-forward` but what's the fun in that.