#!/usr/bin/env bash 

# Script to retrieve orc nightly builds via ssh/rsync

fatal_exit()
{
	[ -n "${1:+x}" ] && printf "%s\n${1}. Aborting"
	exit 1
}

# Add /usr/xpg4/bin to path to use the XPG4 version of tr on Solaris systems, otherwise the script breaks if the locale is (e.g.) UTF8
export PATH=/usr/xpg4/bin:${PATH}

RSYNC=$(which rsync) || fatal_exit "Unable to locate rsync"
CHOWN=$(which chown) || fatal_exit "Unable to locate chown"
# SUDO=$(which sudo) || fatal_exit "Unable to locate sudo"
TR=$(which tr) || fatal_exit "Unable to locate tr"

# Builds we know about - update this list as builds become (un)available
unset VERSIONS
VERSIONS=(GW TS-9 HEAD)

# Create an array "SHORT_VERSIONS" which contains only the first character
# of each element in VERSIONS
unset SHORT_VERSIONS
for i in ${VERSIONS[@]}
do
	SHORT_VERSIONS=(${SHORT_VERSIONS} $i)
done

# Known systems - need to add new platforms to this list as needed e.g. if we support Power going forward
DARWIN="DARWIN"
SUNOS="SUNOS"
LINUX="LINUX"

# Known architectures
X86_64="X86_64"
I386="I386"
SPARC="SPARC"

SYSTEM=$(uname -s | tr "[:lower:]" "[:upper:]")	# e.g SunOS, Linux, Darwin -> SUNOS, LINUX, DARWIN
ISA=$(uname -p | tr "[:lower:]" "[:upper:]") # e.g. sparc, x86_64, i386 -> SPARC, X86_64, I386

DEFAULT_SOURCE_HOST=storage.orcsoftware.com #Default server to download from
ROOT_DIR="/pub/static/common/applications/orc" # Need this created on the source machine if doesn't exist.
DEFAULT_BUILD="7.1" # What to download if the user doesn't explictly choose a build to retrieve
DEFAULT_LATEST_SUCCESS="S" # Download last available (irrespective of whether a complete build) or the last known successful build

# Initialize the list of files/directories to exclude from the sync
EXCLUDE_LIST=""

# Initialize the path to a file containing additional files to exclude from the sync (defaults to /etc/orc_nightly_exclude)
EXCLUDE_FILE_PATH="/etc/orc-nightly-exclude"

# Set EXCLUDE_APPS to a non-null value (e.g. YES) to exclude the Orc apps from the d/l. (Useful for VMs)
EXCLUDE_APPS=""
EXCLUDE_DISTRIB=""
EXCLUDE_PDF=""
EXCLUDE_WIN=""
INCLUDE_PAPILLON=""
INCLUDE_TRADEMONITOR=""
EXCLUDE_FILE=""

# Extract the username of the current user for future use
#SSH_LOGIN=$(id | sed 's/uid=[0-9][0-9]*(\([^)]*\)).*/\1/')"@"
SSH_LOGIN=""

# Source a config file which can override the script variables e.g. EXCLUDE_APPS
CONF_FILE=orc-nightly.conf
if [ -f ./${CONF_FILE} ] ; then 
	source ./${CONF_FILE}
else
	[ -f /etc/${CONF_FILE} ] && source /etc/${CONF_FILE}
fi

if [ -n "${SSH_LOGIN}" ] ; then
	eval "SSH_HOME=~${SSH_LOGIN}"
	if [ -n "SSH_HOME" ] ; then
		while read i
		do
			SSH_IDENTITY=${SSH_IDENTITY}" -i ${i}"
		# Nightmares with piping into a while read loop. Still better than backticks though.
		# Note that the triple redirect is bash 3.0 onwards and that the double-quotes 
		# around the $() are required to produce multiple arguments to read (otherwise the output
		# of the sub-shell is considered a single argument.	
		# In a nutshell, loop through all of the files named id* (but not including the string "pub")
		# in the SSH_LOGIN user's home directory. We'll pass these to ssh to use as potential keys
		# to use when logging into the remote host.
		done <<< "$(ls  ${SSH_HOME}/.ssh/id* 2>/dev/null | grep -v pub)"
	fi
	SSH_LOGIN=${SSH_LOGIN}"@"
fi 

get_build()
{
	PS3="Which build should be downloaded? "
	printf "\n"
	select i in ${VERSIONS[@]}
do
	break
done
if [ -n "${i}" ] ; then
	BUILD="${i}"
	printf "%s\nDownloading ${BUILD}\n"
else
	printf "%s\nDownloading default build - ${DEFAULT_BUILD}\n"
	BUILD=${DEFAULT_BUILD}
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
			y|Y)
			DELETE_FILES="--delete --delete-excluded --force"
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
        read -p "Download (L)atest available build or last (S)uccessful build <${DEFAULT_LATEST_SUCCESS}> " LATEST_OR_SUCCESS
				case ${LATEST_OR_SUCCESS} in
					S|s)
					LATEST_OR_SUCCESS=S
					;;
					L|l)
					LATEST_OR_SUCCESS=L
					;;
					*)
					LATEST_OR_SUCCESS=${DEFAULT_LATEST_SUCCESS}
					;;
				esac
}

set_path()
{
	if [ ${LATEST_OR_SUCCESS} = "L" ] ; then
		L_OR_S="latest"
		BUILD_DESC="latest nightly ${BUILD}"
	else
		L_OR_S="success"
		BUILD_DESC="last successful ${BUILD}"
	fi
	if [ ${BUILD} = "HEAD" ] || [[ ${BUILD} =~ TS-* ]] || [ ${BUILD} = "GW" ] ; then
		ROOT_DIR="/pub/builds/nightly/${BUILD}/${L_OR_S}/release/orc/"
		DEST_DIR="/orcreleases/${BUILD}"
	else
		ROOT_DIR="/pub/builds/nightly/Orc-${BUILD/\./-}/${L_OR_S}/release/orc/" 
		DEST_DIR="/orcreleases/orc-${BUILD}"
	fi
	SOURCE=${ROOT_DIR}

	if [ ${SYSTEM} = ${DARWIN} ] ; then 								# MacOSX only
		if [ ${BUILD} = "HEAD" ] || [[ ${BUILD} =~ TS-* ]] || [ ${BUILD} = "GW" ] ; then	# non-numeric releases don't get the Orc- prefix
			DEST_DIR="/Applications/Orc/"${BUILD}
		else
			DEST_DIR="/Applications/Orc/Orc-"${BUILD}																					# numeric releases do get the Orc- prefix
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
	EXCLUDE_FILE=""
	if [ -f ${EXCLUDE_FILE_PATH} ] ; then
		EXCLUDE_FILE="--exclude-from="${EXCLUDE_FILE_PATH}
	fi
}

download_extras()
# This doesn't work well as the directory tree on the local systems doesn't really match what's in Sthlm. Getting everything in the right place in a 
# consistent manner is ugly as hell. There's also the small problem that nightly builds of Pap aren't useable - they seem to be hard-coded to
# point to a test keycode file.
{
	printf "\nPapillon/TradeMonitor download is enabled. Commencing now.\n\n"
	if [ "${INCLUDE_PAPILLON}" ] ; then
		SOURCE="${ROOT_DIR}/../internal/apps/Papillon.app"
	fi 
	if [ "${INCLUDE_TRADEMONITOR}" ] ; then
		SOURCE="${SOURCE} ${ROOT_DIR}/../internal/apps/TradeMonitor.app"
	fi
	# On non-Mac systems, put the extras into the apps subdirectory of the destination
	if [ ${SYSTEM} != ${DARWIN} ] ; then
		DEST_DIR=${DEST_DIR}/apps
	fi
	CMD="${RSYNC} -rlptzucO --progress ${DELETE_FILES} ${EXCLUDE_LIST} ${EXCLUDE_FILE} -e \"ssh ${SSH_IDENTITY} ${SSH_LOGIN}${SOURCE_HOST}\" \":${SOURCE}\" ${DEST_DIR}"
	eval ${CMD}
	TRANSFER_RESULT=$?
	eval_transfer_result
}

update_permissions()
{
if [ ${SYSTEM} != ${DARWIN} ] ; then #On a Mac/PC there's no Orc user
	printf "\nChanging owner and permissions of new Orc\n"
	cd $DEST_DIR/..
	CMD="${CHOWN} -R orc:orc ${DEST_DIR} 2>/dev/null"
	#TODO add test for sudo - if permitted then use sudo otherwise try to update owner/group without sudo
	#sudo ${CMD} > /dev/null 2>&1 || fatal_exit "Unable to update owner & group of ${DEST_DIR} - please check that you are in sudoers and manually update the owner & group of ${DEST_DIR}"
	eval ${CMD}
fi
}

eval_transfer_result()
{
case ${TRANSFER_RESULT} in
	0)	
	printf "\nSuccessfully installed ${BUILD_DESC} build\n"
	;;

	23)
	printf "\nrsync reported \"unable to transfer some files\"\n"
	;;

	*)
	printf "\nrsync retrieval of "${BUILD_DESC}" reported errors. Please re-run and check the script output.\n"
	;;

esac
unset TRANSFER_RESULT
}

# main()
get_build
get_source_host
get_download_pdf
get_delete
get_latest_or_success
set_path
check_destination
set_exclude_list
set_exclude_file

printf "\nRetrieving $BUILD_DESC build from $SOURCE_HOST\n"

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
# Note also that all the escaped quotes around the -e option and the :$SOURCE are mandatory - don't be tempted to remove them.
CMD="${RSYNC} -rlptzucmO --progress ${DELETE_FILES} ${EXCLUDE_LIST} ${EXCLUDE_FILE} -e \"ssh ${SSH_IDENTITY} ${SSH_LOGIN}${SOURCE_HOST}\" \":${SOURCE}\" ${DEST_DIR}"
eval ${CMD}
TRANSFER_RESULT=$?
eval_transfer_result

# Disable this for now. Doesn't really work the way we want.
# Do a separate rsync for Papillon and/or TradeMonitor
#if [ ${INCLUDE_PAPILLON} -o ${INCLUDE_TRADEMONITOR} ] ; then	
#	download_extras
#fi

update_permissions

exit 0
