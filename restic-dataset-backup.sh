#!/bin/bash
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
VERSION="v0.6"
# Path
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# echo to stderr
echoerr() { printf "%s\n" "$*" >&2; }

fnUsage() {
	echoerr "USAGE: $0 [-c <config-file>]" 1>&2;
	echoerr "  -c <config-file>: path to config file" 1>&2;
	exit 1;
}

# command line arguments
# https://wiki.bash-hackers.org/howto/getopts_tutorial
#echo $*
while getopts "hc:" OPT; do
	case $OPT in
		c)
			CONFIGFILE="$OPTARG"
			;;
		h)
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
HOSTNAME=`hostname`

# runtime measurement
declare -i iSTARTTIME=0
declare -i iENDTIME=0
declare -i iRUNTIME=0
declare -i iRUNTIMEH=0
declare -i iRUNTIMEM=0
declare -i iRUNTIMES=0
iSTARTTIME=$(date +%s)

# load config file
DATASET="none"
RESTIC_REPOSITORY="none"
RESTIC_PASSWORD="none"
AWS_ACCESS_KEY_ID="none"
AWS_SECRET_ACCESS_KEY="none"
HC_URL="none"
KEEP_WITHIN=""
KEEP_MONTHLY=""
if [ -f "$CONFIGFILE" ]; then
	if [ $(stat -c "%u" "$CONFIGFILE") != "0" ]; then
		echoerr "WARNING: $CONFIGFILE should be owned by root because it contains sensible data!"
	fi
	if [ $(stat -c "%a" "$CONFIGFILE") != "600" ]; then
		echoerr "WARNING: $CONFIGFILE should have 600 permissions because it contains sensible data!"
	fi
	source "$CONFIGFILE"
else
	echoerr "$CONFIGFILE not found!"
	exit 1
fi

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
	if [ ! "$HC_URL" == "" ]; then
		echo -n "Connecting to healthchecks.io: "
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
	if [ ! "$HC_URL" == "" ]; then
		echo -n "Connecting to healthchecks.io: "
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
	if [ ! "$HC_URL" == "" ]; then
		echo -n "Connecting to healthchecks.io: "
		curl -fsS --retry 3 --data-raw "$SCRIPTNAME $VERSION: $MESSAGE" "$HC_URL/fail"
		echo ""
	fi
}

fnSendStart "Starting backup: $HOSTNAME"

# root check
if [ $(id -u) -ne 0 ]; then fnSendError "Please run as root!"; exit 1; fi

# check if backup is already running
LOCKSUBDIR=`echo "$RESTIC_REPOSITORY" | md5sum | head -c32`
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

# create snapshot of ZFS dataset
zfs snap "$DATASET"@backup-source
if [ ! $? -eq 0 ]; then fnSendError "Creating snapshot $DATASET@backup-source failed!"; fnCleanup; exit 1; fi

# export some vars
export RESTIC_REPOSITORY
export RESTIC_PASSWORD
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
# Mount point of ZFS dataset
DATASET_MOUNTPOINT=`zfs get -H -o value mountpoint "$DATASET"`

# restic backup
nice -n19 ionice -c3 restic --verbose backup --tag "dataset:$DATASET" --tag "mountpoint:$DATASET_MOUNTPOINT" "$DATASET_MOUNTPOINT"/.zfs/snapshot/backup-source/
if [ ! $? -eq 0 ]; then fnSendError "Restic backup failed!"; fnCleanup; exit 1; fi

# delete snapshot of ZFS dataset
zfs destroy "$DATASET"@backup-source
if [ ! $? -eq 0 ]; then sync; sleep 2; fnSendError "Destroying snapshot $DATASET@backup-source failed!"; fnCleanup; exit 1; fi

# restic forget
if [ ! -z "$KEEP_WITHIN" -a ! -z "$KEEP_MONTHLY" ]; then
	nice -n19 ionice -c3 restic forget --keep-within "$KEEP_WITHIN" --keep-monthly "$KEEP_MONTHLY" --prune
	if [ ! $? -eq 0 ]; then sync; sleep 2; fnSendError "Restic forget failed!"; fnCleanup; exit 1; fi
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
iRUNTIME=$iENDTIME-$iSTARTTIME
iRUNTIMEH=${iRUNTIME}/3600
iRUNTIMEM=(${iRUNTIME}%3600)/60
iRUNTIMES=${iRUNTIME}%60

# send success mesage
fnSendSuccess "OK! Laufzeit: $(printf "%02d:%02d:%02d" $iRUNTIMEH $iRUNTIMEM $iRUNTIMES)."
