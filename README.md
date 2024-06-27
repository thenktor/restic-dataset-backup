# A restic backup script

Creates a snapshot of a ZFS dataset and then runs restic to do a backup.

## Scripts

There are two scripts included:

* `restic-dataset-backup.sh`: Create backup of a single dataset. Uses a dedicated `.conf` file for each dataset.
* `restic-run-all.sh`: Runs backups for all `.conf` files in a directory. Uses a `.all.conf` file.

## Configuration

Copy the `backup.conf.sample` file and edit the copy to your needs. You may want to do the same for the `backup.all.conf.sample` file.
