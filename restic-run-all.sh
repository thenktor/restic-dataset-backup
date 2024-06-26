#!/bin/bash
# Creates backups of ZFS datasets with restic
# Uses healthchecks.io for signaling

# Version
VERSION="v0.1"
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
	exit 1;
}

# command line arguments
# https://wiki.bash-hackers.org/howto/getopts_tutorial
#echo $*
CONFIGFILE=""
while getopts "hc:" OPT; do
	case $OPT in
		c)
			CONFIGFILE="$OPTARG"
			;;
		h)
			fnUsage
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
declare -i iSTARTTIME=0
declare -i iENDTIME=0
declare -i iRUNTIME=0
declare -i iRUNTIMEH=0
declare -i iRUNTIMEM=0
declare -i iRUNTIMES=0
iSTARTTIME=$(date +%s)

if [ -f "$CONFIGFILE" ]; then
	source "$CONFIGFILE"
else
	echoerr "$CONFIGFILE not found!"
	exit 1
fi

fnSendStart () {
	if [ ! "$1" ]; then
		local MESSAGE="Empty message."
	else
		local MESSAGE="$1"
	fi
	echo "$MESSAGE"
	# Ping Healthchecks.io
	if [ -n "$HC_URL" ]; then
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
	if [ -n "$HC_URL" ]; then
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
	if [ -n "$HC_URL" ]; then
		echo -n "Connecting to healthchecks.io: "
		curl -fsS --retry 3 --data-raw "$SCRIPTNAME $VERSION: $MESSAGE" "$HC_URL/fail"
		echo ""
	fi
}

fnSendStart "Starting backups: $HOSTNAME"

# Find all .conf files but exclude .all.conf files
CONF_FILES=$(find "$SEARCH_DIR" -type f -name "*.conf" ! -name "*.all.conf")

# Check if any .conf files were found
if [ -z "$CONF_FILES" ]; then
	fnSendError "No .conf files found."
	exit 1
fi

declare -i iERROR_COUNT=0
ERROR_CONFS=""

# Loop through each .conf file
for CONF_FILE in $CONF_FILES; do
	if ! "$RESTIC_DATASET_BACKUP" -c "$CONF_FILE"; then
		iERROR_COUNT+=1
		ERROR_CONFS="$CONF_FILE $ERROR_CONFS"
	fi
done

# runtime measurement
iENDTIME=$(date +%s)
iRUNTIME=$iENDTIME-$iSTARTTIME
iRUNTIMEH=${iRUNTIME}/3600
iRUNTIMEM=(${iRUNTIME}%3600)/60
iRUNTIMES=${iRUNTIME}%60

if [ -n "$ERROR_CONFS" ]; then
	fnSendError "Errors: $iERROR_COUNT; configs: $ERROR_CONFS; Run time: $(printf "%02d:%02d:%02d" $iRUNTIMEH $iRUNTIMEM $iRUNTIMES)."
else
	fnSendSuccess "OK! Run time: $(printf "%02d:%02d:%02d" $iRUNTIMEH $iRUNTIMEM $iRUNTIMES)."
fi
