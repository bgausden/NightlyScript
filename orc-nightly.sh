#!/usr/bin/env bash 

# Script to retrieve orc nightly builds via ssh/rsync
# What is downloaded and from where can be set via command-line options, a config file or by fail-safe defaults in the script itself.
# The command-line options are explained below.
# The config file will be sourced by this script and must be called orc-nightly.conf and reside either in CWD or in /etc/orc.
# Failsafe values for the script variables are called DEFAULT_* in the script.

fatal_exit()
{
	[ -n "${1:+x}" ] && printf "%s\n${1} Aborting.\n\n"
	exit 1
}

usage()
{
	printf "\n"
	cat <<- EOF
	Usage: $(basename $0) [-a][-c][-d][-o][-h <host>][-l][-p][-r <build>][-s][-t][-w] 

	Supported options are:
		-a        Download all builds (as set in /etc/orc-nightly.conf or as defined as default values in this script
		-b        Exclude PDF's e.g. manuals
		-c        Exclude client applications e.g. Orc Trader & Sauron
		-d        Delete files which do not exist on the server but exist on the client system
		-h        Help
		-l        Download the latest available nightly build (mutually exclusive with -u)
		-o        Exclude contents of <orc install dir>/distrib
		-p        Use non-standard port for connecting to source
		-r        Which build to download - requires an argument - the desired build e.g. TS-9
		-s        Download source - requires an argument - the host to download from
		-t        Include the Trade Monitor client app (excluded by default)
		-u        Download the last successful nightly build (mutually exclusive with -l)
		-w        Exclude windows components e.g. exes and dlls
	EOF
}

description()
{
	cat <<-EOF

	Description: $(basename $0) is a script for downloading via rsync the nightly builds from (typically) Stockholm, via rsync.

	The script provides for downloading either the most recent or the last successful nightly build for any of the 
	available Orc releases, both TS and GW.

  The script accepts a number of command-line options (see Usage) and will also read from a config file which
	is sourced from either $CWD/orc-nightly-config or /etc/orc-nightly-config. If no command-line options are 
	provided and there is no config file found, the script will fall back to hard-coded fail-safe parameters.

	In addition to the config file, the script will read ./orc-nightly-exclude or /etc/orc-nightly-exclude from
	which a list of filename patterns to exclude from the synchronization will be read. The file accepts both
	full and partial pathnames and will perform variable expansion and globbing on the patterns when determining
	which files/directories to exclude.

	The script utilizes SSH to connect to the source. rsync then tunnels vi the SSH connection. If a username is
	specified on the command-line or via the config file, the script will locate all SSH keys in the nominated
	user's $HOME/.ssh/ directory and will use these when attempting to make the SSH connection. If no valid keys
	are found, and if the server permits it, the user will be prompted for a password with which to log in.

	The script requires a directory structure on the destination which mimics that found on the Stockholm servers i.e.

	/pub/builds/nightly/GW/latest/release/orc --soft linked-> /orcreleases/GW/
	
	If the destination path does not exist the script will prompt the user to either proceed (and create the required path) or to abort.
	EOF
}

# The command-line gets clobbered so we need to save it now for parsing later on.
if (( $# > 0 )) ; then
	CMD_LINE="$@"
	HAVE_OPTS=true
else
	HAVE_OPTS=false
fi

# Add /usr/xpg4/bin to path to use the XPG4 version of tr on Solaris systems, otherwise the script breaks if the locale is (e.g.) UTF8
export PATH=/usr/xpg4/bin:${PATH}

RSYNC=$(which rsync) || fatal_exit "Unable to locate rsync"
CHOWN=$(which chown) || fatal_exit "Unable to locate chown"
# SUDO=$(which sudo) || fatal_exit "Unable to locate sudo"
TR=$(which tr) || fatal_exit "Unable to locate tr"

# Builds we know about - update this list as builds become (un)available
unset VERSIONS
VERSIONS=(GW TS-9 HEAD)

# Known systems - need to add new platforms to this list as needed e.g. if we support Power going forward
DARWIN="DARWIN"
WINDOWS="CYGWIN_NT-6.1-WOW64"
SUNOS="SUNOS"
LINUX="LINUX"

# Known architectures
X86_64="X86_64"
I386="I386"
SPARC="SPARC"

SYSTEM=$(uname -s | tr "[:lower:]" "[:upper:]")	# e.g SunOS, Linux, Darwin -> SUNOS, LINUX, DARWIN
ISA=$(uname -p | tr "[:lower:]" "[:upper:]") # e.g. sparc, x86_64, i386 -> SPARC, X86_64, I386

# Failsafe default values
DEFAULT_SOURCE_HOST=scp.orcsoftware.com #Default server to download from
ROOT_DIR="/pub/static/common/applications/orc" # Need this created on the source machine if doesn't exist.  

BUILD="" # What to download if the user doesn't explictly choose a build to retrieve

DEFAULT_LATEST_OR_SUCCESS="L" # Download last available (irrespective of whether a complete build) or the last known successful build

EXCLUDE_LIST="" # Initialize the list of files/directories to exclude from the sync

# Initialize array of paths to search for a file containing additional filename patterns to exclude from the sync
DEREF_LINK=$(readlink -n ${0})
if [ -z ${DEREF_LINK} ] ; then
	EXE_PATH=$(dirname {0})
else
	EXE_PATH=$(dirname ${DEREF_LINK})
fi

EXCLUDE_FILE_PATHS=("${PWD}/orc-nightly-exclude" "/etc/orc-nightly-exclude" ${EXE_PATH}"/orc-nightly-exclude")

# Set EXCLUDE_APPS to a non-null value (e.g. YES) to exclude the Orc apps from the d/l. (Useful for VMs)
EXCLUDE_APPS=""
EXCLUDE_DISTRIB=""
EXCLUDE_PDF=""
EXCLUDE_WIN=""
INCLUDE_TRADEMONITOR=""
EXCLUDE_FILE=""
SSH_LOGIN=""
SSH_PORT="" 

# Source a config file which can override the script variables e.g. EXCLUDE_APPS
# Source both the conf file in the working directory and one (if it exists)
# in /etc. A conf file in /etc/ will take precedence.
CONF_FILE=orc-nightly.conf
[ -f ./${CONF_FILE} ] && source ./${CONF_FILE}
[ -f /etc/${CONF_FILE} ] && source /etc/${CONF_FILE}

# Create a list of ssh identities (keys) which which to try logging in to the source
if [ -n "${SSH_LOGIN}" ] ; then
	# Find all of the current user's private keys. Hopefully one of these matches
	# $SSH_LOGIN and will be accepted by the remote system.
	# Note we can't search $SSH_LOGIN user's .ssh directory for keys because we don't have read access.
	# We're therefore in the odd (?) position of needing to store (e.g.) the orc user's private key
	# in our personal .ssh folder.
	while read i
	do
		if [ ! -z ${i} ] ; then
			SSH_IDENTITY=${SSH_IDENTITY}" -i ${i}"
		fi
		# Nightmares with piping into a while read loop. Still better than backticks though.
		# Note that the triple redirect is bash 3.0 onwards and that the double-quotes 
		# around the $() are required to produce multiple arguments to read (otherwise the output
		# of the sub-shell is considered a single argument.	
		# In a nutshell, loop through all of the files containing the string "PRIVATE" in the user's
		# home directory. We'll pass these to ssh to use as potential keys
		# to use when logging into the remote host.
	done <<< "$(grep -l PRIVATE ~/.ssh/*)"
	SSH_LOGIN_OPTION="-l "${SSH_LOGIN}
else
	SSH_LOGIN_OPTION="-l "$USER
fi 

parse_opts()
{
	# Run through any arguments to make sure they're sane
	while getopts ":abcdhlkp:r:s:twu" OPTION ${CMD_LINE}
do
	case ${OPTION} in
		a)
		# Download all configured builds (as seen in VERSIONS)
		# TODO implement this
		ALL_VERSIONS=true
		;;
		b)
		# Exclude PDFs e.g. manuals
		EXCLUDE_PDF=1
		;;
		c)
		# Exclude client applications
		EXCLUDE_APPS=1 
		;;
		d)
		# Delete files which do not exist on the server and are within the synced directories
		DELETE_FILES="--delete --force"
		;;
		h)
		# Show help
		description
		usage
		fatal_exit ""
		;;
		k)
		# Delete files which do not exist on server even if in directories specifically excluded from sync
		DELETE_FILES="--delete --delete-excluded --force"
		;;
		l)
		# Download latest Nightly
		LATEST_OR_SUCCESS=L
		;;
		o)
		#Exclude contents of distrib e.g. orc monitor
		EXCLUDE_DISTRIB=1
		;;
		p)
		# Use a non-standard port to connect to the source
		SSH_PORT=${OPTARG}
		;;
		r)
		# Which build to download - requires argument
		BUILD=""
		for i in ${VERSIONS[@]} ; do
			if [ ${OPTARG} = ${i} ] ; then
				BUILD=${OPTARG}
				break
			fi
		done
		if [ -z ${BUILD} ] ; then
			fatal_exit "${OPTARG} is not a valid build."
		fi
		;;
		s)
		# Host to sync with - requires argument
		SOURCE_HOST=${OPTARG}
		;;
		t)
		# Include Trade Monitor
		INCLUDE_TRADEMONITOR=1
		;;
		w)
		# Exclude Windows components e.g. exes and dlls
		EXCLUDE_WIN=1
		;;
		u)
		# Download last successful Nightly build
		LATEST_OR_SUCCESS=S
		;;
		*)
		usage
		fatal_exit "%s\nUnknown or malformed option: \"${OPTARG}\""
		;;
	esac
done
}

get_build()
{
	if [ ${ALL_VERSIONS} ] ; then
		printf "%s\nDownloading all available builds\n"
		unset BUILD
		for i in ${VERSIONS[@]} ; do BUILD[${#BUILD[*]}]=$i ; done
	elif [ -z ${BUILD} ] ; then
		PS3="Which build should be downloaded? "
		printf "\n"
		# Print a menu of choices based on VERSIONS and place the user selected option (desired build) into BUILD if non-null
		select i in ${VERSIONS[@]} ; do break ; done
		if [ -n "${i}" ] ; then
			# Valid selection
			BUILD="${i}"
			printf "%s\nDownloading ${BUILD}\n"
		else
			# Invalid selection
			printf "%s\nDownloading default build - ${DEFAULT_BUILD}\n"
			BUILD=${DEFAULT_BUILD}
		fi
	fi
}

get_delete()
{
	printf "\n"
	read -p "Delete files not also on server (dangerous!) <N> " i
	if [ -z ${i} ] ; then
		DELETE_FILES=''
	else
		case ${i} in 
			a|A)
			# Secret option. Deletes files on destination which have been excluded from sync
			# Generally not needed (nor desired) but handy when trimming the contents of the
			# destination to match the source (taking into account excludes)
			DELETE_FILES="--delete --delete-excluded --force"
			;; 
			y|Y)
			DELETE_FILES="--delete --force"
			;; 
			*) 
			DELETE_FILES=""
			;;
		esac
	fi
}

get_source_host()
{
	printf "\n"
	read -p "Sync with which server <${DEFAULT_SOURCE_HOST}> " SOURCE_HOST
	[ -z ${SOURCE_HOST} ] && SOURCE_HOST=${DEFAULT_SOURCE_HOST}
}

# This is slightly problematic. If we exclude PDFs from the sync, and, choose to delete files
# on the client which aren't on the server, we end up deleting all of the PDFs on the client
# rather than just skipping syncing them... EXCLUDE_PDF="Y" + DELETE_FILES isn't a good combo.
get_download_pdf()
{
	printf "\n"
	if [ ${EXCLUDE_PDF} ] ; then
	 	DOWNLOAD_PDF_CONFIG="N"
	else
		DOWNLOAD_PDF_CONFIG="Y"
	fi
	read -p "Download PDFs <${DOWNLOAD_PDF_CONFIG}> " DOWNLOAD_PDF
	[ -z ${DOWNLOAD_PDF} ] && DOWNLOAD_PDF=${DOWNLOAD_PDF_CONFIG}
	# If we *do* want to download PDFs then we *don't* want to exclude them.
	# PDFs will be excluded if EXCLUDE_PDF is non-null.
	# PDFs will be included (downloaded) if EXCLUDE_PDF is null
	if [ ${DOWNLOAD_PDF} = "Y" -o ${DOWNLOAD_PDF} = "y" ] ; then
		EXCLUDE_PDF=""
	else
		EXCLUDE_PDF="Y"
	fi
}

get_latest_or_success()
{
        printf "\n"
        read -p "Download (L)atest available build or last (S)uccessful build <${DEFAULT_LATEST_OR_SUCCESS}> " LATEST_OR_SUCCESS
				case ${LATEST_OR_SUCCESS} in
					S|s)
					LATEST_OR_SUCCESS=S
					;;
					L|l)
					LATEST_OR_SUCCESS=L
					;;
					*)
					LATEST_OR_SUCCESS=${DEFAULT_LATEST_OR_SUCCESS}
					;;
				esac
}

set_path()
{
	if [ ${LATEST_OR_SUCCESS} = "L" ] ; then
		L_OR_S="latest"
		DOWNLOAD_BUILD_DESC="latest nightly ${DOWNLOAD_BUILD}"
	else
		L_OR_S="success"
		DOWNLOAD_BUILD_DESC="last successful ${DOWNLOAD_BUILD}"
	fi
	case ${DOWNLOAD_BUILD} in
		HEAD|TS*|GW*)
			ROOT_DIR="/pub/builds/nightly/${DOWNLOAD_BUILD}/${L_OR_S}/release/orc/"
			DEST_DIR="/orcreleases/${DOWNLOAD_BUILD}"
			;;
		*MIN)
			ROOT_DIR="/pub/builds/nightly/${DOWNLOAD_BUILD}/${L_OR_S}/release/gateways/"
			DEST_DIR="/orcreleases/${DOWNLOAD_BUILD}"
			;;
		*)
			ROOT_DIR="/pub/builds/nightly/Orc-${DOWNLOAD_BUILD/\./-}/${L_OR_S}/release/orc/" 
			DEST_DIR="/orcreleases/orc-${DOWNLOAD_BUILD}"
			;;
	esac
	
	SOURCE=${ROOT_DIR}

	if [ ${SYSTEM} = ${DARWIN} ] ; then 								# MacOSX only
		if [ ${DOWNLOAD_BUILD} = "HEAD" ] || [[ ${DOWNLOAD_BUILD} =~ TS-* ]] || [ ${DOWNLOAD_BUILD} = "GW" ] ; then	# non-numeric releases don't get the Orc- prefix
			DEST_DIR="/Applications/Orc/"${DOWNLOAD_BUILD}
		else
			DEST_DIR="/Applications/Orc/Orc-"${DOWNLOAD_BUILD}																					# numeric releases do get the Orc- prefix
		fi
		SOURCE="	${ROOT_DIR}/apps/ \
		${ROOT_DIR}/lib/liquidator.jar \
		${ROOT_DIR}/lib/lprofiler.jar \
		${ROOT_DIR}/doc \
		${ROOT_DIR}/sdk "
	fi
	#TODO Fix this so it works for all users
	if [ ${SYSTEM} = ${WINDOWS} ] ; then 								# Win only
		if [ ${DOWNLOAD_BUILD} = "HEAD" ] || [[ ${DOWNLOAD_BUILD} =~ TS-* ]] || [ ${DOWNLOAD_BUILD} = "GW" ] ; then	# non-numeric releases don't get the Orc- prefix
			DEST_DIR="\"/cygdrive/c/Users/jeanm/Orc/"${DOWNLOAD_BUILD}\"
		else
			DEST_DIR="\"/cygdrive/c/Users/jeanm/Orc/Orc-"${DOWNLOAD_BUILD}\"																					# numeric releases do get the Orc- prefix
		fi
		SOURCE="	${ROOT_DIR}/apps/ \
		${ROOT_DIR}/lib/liquidator.jar \
		${ROOT_DIR}/lib/lprofiler.jar \
		${ROOT_DIR}/doc \
		${ROOT_DIR}/sdk "
	fi
}

check_destination()
{
	if [ ! -d ${DEST_DIR} ] ; then
		printf "\n"
		read -p "Destination directory (${DEST_DIR}) does not exist, create? <N> " CREATE_DESTINATION
		case ${CREATE_DESTINATION} in
			Y|y)
			mkdir -p ${DEST_DIR} > /dev/null || fatal_exit "Unable to create ${DEST_DIR}"
			;;
			*)
			exit 0
			;;
		esac
	fi
}

set_exclude_list()
{
	CVS="--exclude=\*/CVS/"															# CVS
	CYGWIN="--exclude=i386-pc-cygwin/"									# Cygwin
	LINUX32="--exclude=i386-unknown-linux/"							# 32bit Linux
	DISTRIB="--exclude=distrib/"												# Orc Monitor
	LOGS="--exclude=log/\*"															# Logs
	APPS="--exclude=apps/"															# Apps
	PDF="--exclude=\*.pdf"															# PDF Documentation
	ALLSUNOS="--exclude=arch/\*solaris\*"								# Solaris x86_64 & SPARC
	ALLLINUX="--exclude=arch/\*linux\*"									# Linux all flavours
	ALLDARWIN="--exclude=arch/\*darwin\*"								# Mac
	WINDOWS_EXES="--exclude=\*.dll --exclude=\*.exe"		# DLLs and EXEs
	X86_64_SUN="--exclude=arch/x86_64-sun\*/"						# Solaris x86_64
	SPARC_SUN="--exclude=arch/sparc-sun\*/"							# Solaris SPARC

	EXCLUDE_LIST="${CVS} ${CYGWIN} ${LINUX32} ${LOGS}"

	[ ${SYSTEM} != ${SUNOS} ] && EXCLUDE_LIST=${EXCLUDE_LIST}" ${ALLSUNOS}"
	[ ${SYSTEM} != ${LINUX} ] && EXCLUDE_LIST=${EXCLUDE_LIST}" ${ALLLINUX}"
	[ ${SYSTEM} != ${DARWIN} ] && EXCLUDE_LIST=${EXCLUDE_LIST}" ${ALLDARWIN}"

	[ ${SYSTEM} = ${SUNOS} ] && [ ${ISA} != ${SPARC} ] && EXCLUDE_LIST=${EXCLUDE_LIST}" ${SPARC_SUN}"
	[ ${SYSTEM} = ${SUNOS} ] && [ ${ISA} != ${I386} ] && EXCLUDE_LIST=${EXCLUDE_LIST}" ${X86_64_SUN}"
	
	[ "${EXCLUDE_APPS}" ] && EXCLUDE_LIST=${EXCLUDE_LIST}" ${APPS}"
	[ "${EXCLUDE_DISTRIB}" ] && EXCLUDE_LIST=${EXCLUDE_LIST}" ${DISTRIB}"
	[ "${EXCLUDE_PDF}" ] && EXCLUDE_LIST=${EXCLUDE_LIST}" ${PDF}"
	[ "${EXCLUDE_WIN}" ] && EXCLUDE_LIST=${EXCLUDE_LIST}" ${WINDOWS_EXES}"
}

set_exclude_file()
{
	for i in ${EXCLUDE_FILE_PATHS[*]}
	do
		[ -f ${i} ] && EXCLUDE_FILE="--exclude-from="$i
	done
}

download_extras()
# This doesn't work well as the directory tree on the local systems doesn't really match what's in Sthlm. Getting everything in the right place in a consistent manner is ugly as hell.
{
	if [ "${INCLUDE_TRADEMONITOR}" ] ; then
		SOURCE="${SOURCE} ${ROOT_DIR}/../internal/apps/TradeMonitor.app"
	fi
	# On non-Mac systems, put the extras into the apps subdirectory of the destination
	[ ${SYSTEM} != ${DARWIN} ] && DEST_DIR=${DEST_DIR}/apps
	CMD="${RSYNC} -rlptzucO --progress ${DELETE_FILES} ${EXCLUDE_LIST} ${EXCLUDE_FILE} -e \"ssh ${SSH_IDENTITY} ${SSH_PORT_OPTION} ${SSH_LOGIN_OPTION}${SOURCE_HOST}\" \":${SOURCE}\" ${DEST_DIR}"
	eval ${CMD}
	TRANSFER_RESULT=$?
	eval_transfer_result
}

update_permissions()
{
if [ ${SYSTEM} != ${DARWIN} ] ; then #On a Mac/PC there's no Orc user
	printf "\nChanging owner and permissions of new Orc\n"
	pushd $DEST_DIR/.. > /dev/null 2>&1
	CMD="${CHOWN} -R orc:orc ${DEST_DIR} 2>/dev/null"
	#TODO add test for sudo - if permitted then use sudo otherwise try to update owner/group without sudo
	#sudo ${CMD} > /dev/null 2>&1 || fatal_exit "Unable to update owner & group of ${DEST_DIR} - please check that you are in sudoers and manually update the owner & group of ${DEST_DIR}"
	eval ${CMD}
	popd > /dev/null 2>&1
fi
}

download_build()
{
	printf "\nRetrieving $DOWNLOAD_BUILD_DESC build from $SOURCE_HOST\n\n"

	# rsync flags are 
	# -r	recurse into directories
	# -l	copy symlinks as symlinks
	# -p	preserve permissions
	# -t	preserve times
	# -O	omit directories from timestamp preservation
	# -v	increase verbosity
	# -z	compress file data during the transfer
	# -u	(update) skip files that are newer on the receiver
	# -c	(checksum) skip based on checksum, not mod-time & size (high I/O but potentially less to transmit)
	# ${DELETE_FILES} (--delete) delete extraneous files from dest dirs
	# Note: Do not be tempted to add -m - this will delete the log folder from the system and the Orc binaries won't start
	# Note also that all the escaped quotes around the -e option and the :$SOURCE are mandatory - don't be tempted to remove them.
	#TODO pipe 2 > /dev/null
	CMD="${RSYNC} -rlptzucO --rsync-path=rsync --progress ${DELETE_FILES} ${EXCLUDE_LIST} ${EXCLUDE_FILE} -e \"ssh ${SSH_IDENTITY} ${SSH_PORT_OPTION} ${SSH_LOGIN_OPTION}\" \"${SOURCE_HOST}:${SOURCE}\" \"${DEST_DIR}\""
	eval ${CMD}
	TRANSFER_RESULT=$?
}

eval_transfer_result()
{
case ${TRANSFER_RESULT} in
	0)	
	printf "\nSuccessfully installed ${DOWNLOAD_BUILD_DESC} build\n"
	;;

	23)
	printf "\nrsync reported \"unable to transfer some files\"\n"
	;;

	*)
	printf "\nrsync retrieval of "${DOWNLOAD_BUILD_DESC}" reported errors. Please re-run and check the script output.\n"
	;;

esac
unset TRANSFER_RESULT
}

# main()
parse_opts
get_build
if [[ ${HAVE_OPTS} = false ]] ; then
	# Prompt user for download options
	get_source_host
	get_download_pdf
	get_delete
  get_latest_or_success
else
	[ -z ${BUILD} ] && BUILD=${DEFAULT_BUILD}
	[ -z ${SOURCE_HOST} ] && SOURCE_HOST=${DEFAULT_SOURCE_HOST}
	[ -z ${DELETE} ] && DELETE=${DEFAULT_DELETE}
	[ -z ${LATEST_OR_SUCCESS} ] && LATEST_OR_SUCCESS=${DEFAULT_LATEST_OR_SUCCESS}
fi
set_exclude_list
set_exclude_file
for DOWNLOAD_BUILD in ${BUILD[*]}
do
	set_path
	check_destination
	[[ ! -z ${SSH_PORT} ]] && SSH_PORT_OPTION="-p "${SSH_PORT}
	download_build
	eval_transfer_result
	#TODO fix this
	#if [ "${INCLUDE_TRADEMONITOR}" ] ; then	
	#	download_extras
	#fi
	update_permissions
done

exit 0
