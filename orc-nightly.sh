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
VERSIONS=(6.1 7.1 8.0 HEAD)

# Create an array "SHORT_VERSIONS" which contains only the first character
#+ of each element in VERSIONS
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

#PATH=/usr/sbin:/bin:/usr/bin:/usr/local/bin:/opt/sfw/bin
#export PATH

DEFAULT_SOURCE_HOST=storage.orcsoftware.com #Default server to download from
ROOT_DIR="/pub/static/common/applications/orc" # Need this created on the source machine if doesn't exist.
DEFAULT_BUILD="7.1" # What to download if the user doesn't explictly choose a build to retrieve
DEFAULT_LATEST_SUCCESS="L" # Download last available (irrespective of whether a complete build) or the last known successful build

# Set EXCLUDE_APPS to a non-null value (e.g. YES) to exclude the Orc apps from the d/l. (Useful for VMs)
EXCLUDE_APPS=""

SSH_LOGIN=$(id | sed 's/uid=[0-9][0-9]*(\([^)]*\)).*/\1/')

EXCLUDE_LIST=""

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
			DELETE_FILES="--delete"
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
	if [ ${LATEST_OR_SUCCESS}=L ] ; then
		L_OR_S="latest"
	else
		L_OR_S="success"
	fi
	if [ ${BUILD} = "HEAD" ] ; then
		ROOT_DIR="/pub/builds/nightly/${BUILD}/${L_OR_S}/release/orc/"
	else
		# Need to change (e.g.) Orc-7.1 to Orc-7-1 to suit the dir structure in Sthlm.
		ROOT_DIR="/pub/builds/nightly/Orc-${BUILD/\./-}/${L_OR_S}/release/orc/" 
	fi
	BUILD_DESC="Nightly ${BUILD}"
	DEST_DIR="/orcreleases/orc-${BUILD}"
	SOURCE=${ROOT_DIR}
	if [ ${SYSTEM} = ${DARWIN} ] ; then
		DEST_DIR="/Applications/Orc-"${BUILD}
		SOURCE="	${ROOT_DIR}/apps/Orc.app \
		${ROOT_DIR}/apps/Sauron.app \
		${ROOT_DIR}/lib/liquidator.jar \
		${ROOT_DIR}/lib/lprofiler.jar \
		${ROOT_DIR}/apps/Documentation/OrcTraderManual.pdf \
		${ROOT_DIR}/apps/Documentation/ReleaseNotes.pdf \
		${ROOT_DIR}/apps/Documentation/MarketLinks.pdf \
		${ROOT_DIR}/doc \
		${ROOT_DIR}/sdk/liquidator/Documentation \
		${ROOT_DIR}/sdk/liquidator/Examples \
		${ROOT_DIR}/sdk/op "
	fi
	BUILD_DESC="last successful "${BUILD_DESC}
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
	APPS="--exclude=apps"																# Apps
	ALLSUNOS="--exclude=arch/\*solaris\*"								# Solaris x86_64 & SPARC
	ALLLINUX="--exclude=arch/\*linux\*"									# Linux all flavours
	ALLDARWIN="--exclude=arch/\*darwin\*"								# Mac
	WINDOWS_EXES="--exclude=\*.dll --exclude=\*.exe"		# DLLs and EXEs
	X86_64_SUN="--exclude=arch/x86_64-sun\*/"						# Solaris x86_64
	SPARC_SUN="--exclude=arch/sparc-sun\*/"							# Solaris SPARC

	EXCLUDE_LIST="${CVS} ${CYGWIN} ${LINUX32} ${DISTRIB} ${LOGS}"

	[ ${SYSTEM} != ${SUNOS} ] && EXCLUDE_LIST=${EXCLUDE_LIST}" ${ALLSUNOS}"
	[ ${SYSTEM} != ${LINUX} ] && EXCLUDE_LIST=${EXCLUDE_LIST}" ${ALLLINUX}"
	[ ${SYSTEM} != ${DARWIN} ] && EXCLUDE_LIST=${EXCLUDE_LIST}" ${ALLDARWIN}"

	[ ${SYSTEM} = ${SUNOS} ] && [ ${ISA} != ${SPARC} ] && EXCLUDE_LIST=${EXCLUDE_LIST}" ${SPARC_SUN}"
	[ ${SYSTEM} = ${SUNOS} ] && [ ${ISA} != ${I386} ] && EXCLUDE_LIST=${EXCLUDE_LIST}" ${X86_64_SUN}"
	
	[ "${EXCLUDE_APPS}" ] && EXCLUDE_LIST=${EXCLUDE_LIST}" ${APPS}"
}

# main()
get_build
get_source_host
get_delete
get_latest_or_success
set_path
check_destination
set_exclude_list

printf "\nRetrieving $BUILD_DESC build from $SOURCE_HOST\n"

# rsync flags are 
# -r	recurse into directories
# -l	copy symlinks as symlinks
# -p	preserve permissions
# -t	preserve times
# -v	increase verbosity
# -z	compress file data during the transfer
# -u	(update) skip files that are newer on the receiver
# -c	(checksum) skip based on checksum, not mod-time & size (high I/O but potentially less to transmit)
# ${DELETE_FILES} (--delete) delete extraneous files from dest dirs
# Note also that all the escaped quotes around the -e option and the :$SOURCE are mandatory - don't be tempted to remove them.
CMD="${RSYNC} -rlptzuc --progress ${DELETE_FILES} ${EXCLUDE_LIST} -e \"ssh ${SOURCE_HOST}\" \":${SOURCE}\" ${DEST_DIR}"
eval ${CMD}
TRANSFER_RESULT=$?

if [ ${SYSTEM} != ${DARWIN} ] ; then #On a Mac/PC there's no Orc user
	printf "\nChanging owner and permissions of new Orc\n"
	cd $DEST_DIR/..
	CMD="${CHOWN} -R orc:orc ${DEST_DIR}"
	#TODO add test for sudo - if permitted then use sudo otherwise try to update owner/group without sudo
	#sudo ${CMD} > /dev/null 2>&1 || fatal_exit "Unable to update owner & group of ${DEST_DIR} - please check that you are in sudoers and manually update the owner & group of ${DEST_DIR}"
	eval ${CMD}
fi

case ${TRANSFER_RESULT} in
	0)	
	printf "\nSuccessfully installed ${BUILD_DESC} build\n"
	;;

	23)
	printf "\nrsync reported \"nothing to transfer\"\n"
	;;

	*)
	printf "\nrsync retrieval of "${BUILD_DESC}" reported errors. Please re-run and check the script output.\n"
	;;

esac

exit 0
