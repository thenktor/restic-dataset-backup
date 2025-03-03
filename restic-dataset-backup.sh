#!/bin/sh
# shellcheck disable=SC3043

# Creates backups of ZFS datasets with restic
# Uses healthchecks.io for signaling

###############################################################################
# Define your variables here
###############################################################################

# Please use the config file!

###############################################################################
# End of user defined variables
###############################################################################

# Version
VERSION="v0.12"
# Path
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
# /usr/local/bin
if [ -d /usr/local/bin ]; then PATH="/usr/local/bin:$PATH"; fi
# /usr/local/sbin
if [ -d /usr/local/sbin ]; then PATH="/usr/local/sbin:$PATH"; fi
# OmniOS Community Edition
if [ -d /opt/ooce/bin ]; then PATH="/opt/ooce/bin:$PATH"; fi
# pkgsrc (https://pkgsrc.smartos.org/)
if [ -d /opt/local/bin ]; then PATH="/opt/local/bin:$PATH"; fi
export PATH

# echo to stderr
echoerr() { printf "%s\n" "$*" >&2; }

fnUsage() {
	echoerr "USAGE: $0 [-c <config-file>]" 1>&2;
	echoerr "  -c <config-file>: path to config file" 1>&2;
	echoerr "  -i                run 'restic init' on repo" 1>&2;
	echoerr "  -u                run 'restic unlock' on repo" 1>&2;
	exit 1;
}

# command line arguments
# https://wiki.bash-hackers.org/howto/getopts_tutorial
#echo $*
CONFIGFILE=""
INIT=""
UNLOCK=""
while getopts "hiuc:" OPT; do
	case $OPT in
		c)
			CONFIGFILE="$OPTARG"
			;;
		h)
			fnUsage
			;;
		i)
			INIT="YES"
			;;
		u)
			UNLOCK="YES"
			;;
		*)
			fnUsage
			;;
	esac
done

# mandatory arguments
if [ ! "$CONFIGFILE" ]; then
	fnUsage;
fi

# Absolute path to this script, e.g. /home/user/bin/foo.sh
SCRIPT=$(readlink -f "$0")
# Name of the script
SCRIPTNAME=$(basename "$SCRIPT")
# Hostname
HOSTNAME=$(hostname)

# runtime measurement
iSTARTTIME=0
iENDTIME=0
iRUNTIME=0
iRUNTIMEH=0
iRUNTIMEM=0
iRUNTIMES=0
iSTARTTIME=$(date +%s)

# load config file
DATASET="none"
RESTIC_REPOSITORY="none"
RESTIC_PASSWORD="none"
RESTIC_ARGS=""
AWS_ACCESS_KEY_ID="none"
AWS_SECRET_ACCESS_KEY="none"
HC_URL=""
KEEP_WITHIN=""
KEEP_MONTHLY=""
RCLONE_PROGRAM=""
PATH_APPEND=""
if [ -f "$CONFIGFILE" ]; then
	if [ "$(uname)" = "FreeBSD" ]; then
		if [ "$(stat -f '%u' "$CONFIGFILE")" != "0" ]; then
			echoerr "WARNING: $CONFIGFILE should be owned by root because it contains sensible data!"
		fi
		if [ "$(stat -f '%Lp' "$CONFIGFILE")" != "600" ]; then
			echoerr "WARNING: $CONFIGFILE should have 600 permissions because it contains sensible data!"
		fi
	else
		if [ "$(stat -c '%u' "$CONFIGFILE")" != "0" ]; then
			echoerr "WARNING: $CONFIGFILE should be owned by root because it contains sensible data!"
		fi
		if [ "$(stat -c '%a' "$CONFIGFILE")" != "600" ]; then
			echoerr "WARNING: $CONFIGFILE should have 600 permissions because it contains sensible data!"
		fi
	fi
	. "$CONFIGFILE"
	if [ -n "$PATH_APPEND" ]; then
		PATH="$PATH:$PATH_APPEND"
		export PATH
	fi
else
	echoerr "$CONFIGFILE not found!"
	exit 1
fi

fnYesNo() {
	REPLY="x"
	while [ "${REPLY}" != "" ]; do
		printf " (y/n) "
		read -r  REPLY
		REPLY=$(echo "$REPLY" | head -c1 | tr '[:upper:]' '[:lower:]')
		if [ "$REPLY" = "y" ]; then
			echo "YES"
			REPLY=""
			return 0
		elif [ "$REPLY" = "n" ]; then
			echo "NO"
			REPLY=""
			return 1
		else
			echo "Only y/n is allowed as answer"
			REPLY="x"
		fi
	done
}

fnCleanup () {
	if [ -e "$DATASET_MOUNTPOINT"/.zfs/snapshot/backup-source/ ]; then
		zfs destroy "$DATASET"@backup-source
	fi
	if [ -e "$LOCKDIR" ]; then
		rm -rf "$LOCKDIR"
	fi
}

fnSendStart () {
	if [ ! "$1" ]; then
		local MESSAGE="Empty message."
	else
		local MESSAGE="$1"
	fi
	echo "$MESSAGE"
	# Ping Healthchecks.io
	if [ -n "$HC_URL" ]; then
		printf "Connecting to healthchecks.io: "
		curl -fsS --retry 3 --data-raw "$SCRIPTNAME $VERSION: $MESSAGE" "$HC_URL/start"
		echo ""
	fi
}

fnSendSuccess () {
	if [ ! "$1" ]; then
		local MESSAGE="Empty message."
	else
		local MESSAGE="$1"
	fi
	echo "$MESSAGE"
	# Ping Healthchecks.io
	if [ -n "$HC_URL" ]; then
		printf "Connecting to healthchecks.io: "
		curl -fsS --retry 3 --data-raw "$SCRIPTNAME $VERSION: $MESSAGE" "$HC_URL"
		echo ""
	fi
}

fnSendError () {
	if [ ! "$1" ]; then
		local MESSAGE="Undefined error!"
	else
		local MESSAGE="$1"
	fi
	echoerr "$MESSAGE"
	# Ping Healthchecks.io
	if [ -n "$HC_URL" ]; then
		printf "Connecting to healthchecks.io: "
		curl -fsS --retry 3 --data-raw "$SCRIPTNAME $VERSION: $MESSAGE" "$HC_URL/fail"
		echo ""
	fi
}

fnSendStart "Starting backup: ${HOSTNAME}, ${DATASET}"

# root check
if [ "$(id -u)" -ne 0 ]; then fnSendError "Please run as root!"; exit 1; fi

# Repository type, get the part before first ":"
RESTIC_REPOSITORY_TYPE="${RESTIC_REPOSITORY%%:*}"

# check some vars
if [ "$RESTIC_REPOSITORY_TYPE" = "s3" ]; then
	if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
		fnSendError "S3 variables not set!"
		exit 1
	fi
elif [ "$RESTIC_REPOSITORY_TYPE" = "rclone" ]; then
	if [ -z "$RCLONE_PROGRAM" ]; then
		fnSendError "rclone program not set!"
		exit 1
	fi
	RESTIC_ARGS="-o rclone.program=$RCLONE_PROGRAM"
fi

# check if backup is already running
LOCKSUBDIR=$(echo "$RESTIC_REPOSITORY" | md5sum | head -c32)
LOCKPARENTDIR="/tmp/restic-dataset-backup"
if [ ! -e "$LOCKPARENTDIR" ]; then
	mkdir "$LOCKPARENTDIR"
fi
LOCKDIR="$LOCKPARENTDIR/$LOCKSUBDIR"
if mkdir "$LOCKDIR"; then
	echo "Locking succeeded."
else
	fnSendError "Lock failed!"
	exit 1
fi

# export some vars
export RESTIC_REPOSITORY
export RESTIC_PASSWORD
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY

# init restic repo?
if [ "$INIT" = "YES" ]; then
	printf "Do you really want to run 'restic init'?"
	if fnYesNo; then
		if ! restic "$RESTIC_ARGS" init; then
			fnSendError "Restic init failed!"
			fnCleanup
			exit 1
		else
			fnSendSuccess "Restic init done!"
			fnCleanup
			exit 0
		fi
	else
		fnSendSuccess "Restic init aborted!"
		fnCleanup
		exit 0
	fi
fi

# unlock restic repo?
if [ "$UNLOCK" = "YES" ]; then
	printf "Do you really want to run 'restic unlock' to remove stale locks?"
	if fnYesNo; then
		if ! restic "$RESTIC_ARGS" unlock; then
			fnSendError "Restic unlock failed!"
			fnCleanup
			exit 1
		else
			fnSendSuccess "Restic unlock done!"
			fnCleanup
			exit 0
		fi
	else
		fnSendSuccess "Restic unlock aborted!"
		fnCleanup
		exit 0
	fi
fi

# create snapshot of ZFS dataset
if ! zfs snap "$DATASET"@backup-source; then fnSendError "Creating snapshot $DATASET@backup-source failed!"; fnCleanup; exit 1; fi

# Mount point of ZFS dataset
DATASET_MOUNTPOINT=$(zfs get -H -o value mountpoint "$DATASET")

# restic backup
if ! nice -n19 restic "$RESTIC_ARGS" --verbose backup --tag "dataset:$DATASET" --tag "mountpoint:$DATASET_MOUNTPOINT" "${DATASET_MOUNTPOINT}/.zfs/snapshot/backup-source/"; then
	fnSendError "Restic backup failed!"
	fnCleanup
	exit 1
fi

# delete snapshot of ZFS dataset
if ! zfs destroy "$DATASET"@backup-source; then
	sync; sleep 2; fnSendError "Destroying snapshot $DATASET@backup-source failed!"
	fnCleanup
	exit 1
fi

# restic forget
if [ -n "$KEEP_WITHIN" ] && [ -n "$KEEP_MONTHLY" ]; then
	if ! nice -n19 restic "$RESTIC_ARGS" forget --keep-within "$KEEP_WITHIN" --keep-monthly "$KEEP_MONTHLY" --prune; then
		sync; sleep 2; fnSendError "Restic forget failed!"
		fnCleanup
		exit 1
	fi
fi

# unset some vars
unset RESTIC_REPOSITORY
unset RESTIC_PASSWORD
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY

# remove lock dir
rm -rf "$LOCKDIR"

# runtime measurement
iENDTIME=$(date +%s)
iRUNTIME=$((iENDTIME - iSTARTTIME))
iRUNTIMEH=$((iRUNTIME / 3600))
iRUNTIMEM=$(( (iRUNTIME % 3600) / 60 ))
iRUNTIMES=$((iRUNTIME % 60))

# send success mesage
fnSendSuccess "OK! Run time: $(printf "%02d:%02d:%02d" "$iRUNTIMEH" "$iRUNTIMEM" "$iRUNTIMES")."
