#!/bin/sh 

# Script to retrieve orc nightly builds via ssh/rsync

# Known systems - need to add new platforms to this list as needed e.g. if we support Power4 going forwards
DARWIN="DARWIN"
SUNOS="SUNOS"
LINUX="LINUX"

SYSTEM=$(uname -s | tr "[:lower:]" "[:upper:]")	# e.g SunOS, Linux, Darwin -> SUNOS, LINUX, DARWIN
ISA=$(uname -p | tr "[:lower:]" "[:upper:]") # e.g. sparc, x86_64, i386 -> SPARC, X86_64, I386

if [ ${SYSTEM} = ${LINUX} ] ; then
	ECHO="/bin/echo -e"
else
	ECHO="/bin/echo"
fi

fatal_exit()
{
	${ECHO}
	[ -n "${1:+x}" ] && ${ECHO} ${1}". Aborting"
	exit 1
}

PATH=/usr/sbin:/bin:/usr/bin:/usr/local/bin:/opt/sfw/bin
export PATH

DEFAULT_SOURCE_HOST=linuxdev1 #Default server to download from
[ `uname -n` = linuxdev1 ] && DEFAULT_SOURCE_HOST=storage.orcsoftware.com
ROOT_DIR="/pub/static/common/applications/orc" # Need this created on the source machine if doesn't exist.
DEFAULT_BUILD="7.1" # What to download if the user doesn't explictly choose a build to retrieve
DEFAULT_LATEST_SUCCESS="L" # Download last available (irrespective of whether a complete build) or the last known successful build

RSYNC=$(which rsync) || fatal_exit "Unable to locate rsync"
CHOWN=$(which chown) || fatal_exit "Unable to locate chown"
  SUDO=$(which sudo) || fatal_exit "Unable to locate sudo"

SSH_LOGIN=$(id | sed 's/uid=[0-9][0-9]*(\([^)]*\)).*/\1/')

EXCLUDE_LIST=""

get_build()
{
    while
        ${ECHO}
        read -p "Download which build - 6.1, 7.1, 8.0, (H)EAD or (Q)uit? <${DEFAULT_BUILD}> " -e BUILD
        [ -z ${BUILD} ] && BUILD=${DEFAULT_BUILD}
        # grep for an acceptable response and convert to uppercase using tr(anslate)
        BUILD=`${ECHO} ${BUILD} | egrep '7\.1|8\.0|9\.0|[Hh]|[Qq]' | tr '[:lower:]' '[:upper:]'`
        # if $BUILD is non-null, then test returns 1 and we exit the while loop
        #test ${BUILD}"_" = "_"
				[ -z ${BUILD} ]
    do
        ${ECHO} ""
    done
    if [ ${BUILD} = "H" ] ; then
        BUILD="HEAD"
    fi
}

get_delete()
{
	DELETE_FILES=N
	while :
	do
		${ECHO}
		${ECHO} "Delete files not also on server (dangerous!) <"${DELETE_FILES}"> \c"
		read DELETE_FILES
		case ${DELETE_FILES:=N} in 
			n|N) 
				DELETE_FILES=""
				break
				;;
			y|Y) 
				DELETE_FILES="--delete"
				break 
				;; 
		esac
	done
	}

get_source_host()
{
	${ECHO}
	${ECHO} "Sync with which server <"${DEFAULT_SOURCE_HOST}"> \c"
	read SOURCE_HOST
	[ -z ${SOURCE_HOST} ] && SOURCE_HOST=${DEFAULT_SOURCE_HOST}
}

get_latest_or_success()
{
        ${ECHO}
        ${ECHO} "Download (L)atest available build or last (S)uccessful build <${DEFAULT_LATEST_SUCCESS}> \c"   
        read LATEST_OR_SUCCESS
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
		ROOT_DIR="/pub/builds/nightly/Orc-${BUILD/\./-}/${L_OR_S}/release/orc/" # Need to change (e.g.) Orc-7.1 to Orc-7-1 to suit the dir structure in Sthlm.
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
        ${ECHO}
        ${ECHO} "Destination directory (${DEST_DIR}) does not exist, creating."
				mkdir -p ${DEST_DIR} > /dev/null || fatal_exit "Unable to create ${DEST_DIR}"
    fi
}

set_exclude_list()
{
	EXCLUDE_LIST="--exclude=\*/CVS/ \
								--exclude=arch/i386-pc-cygwin/ \
								--exclude=i386-unknown-linux \
								--exclude=\*apple-darwin/ \
								--exclude=\*-gcc..\* \
								--exclude=x86_64-sun-solaris/ \
								--exclude=x86_64-unknown-linux-gcc \
								--exclude=apps/httpd\* \
								--exclude=log/\*"
	if [ ${SYSTEM} != ${SUNOS} ] ; then
		EXCLUDE_LIST=${EXCLUDE_LIST}" --exclude=\*sparc\*"
	fi
	if [ ${SYSTEM} = ${DARWIN} ] ; then
		EXCLUDE_LIST=${EXCLUDE_LIST}" --exclude=\*.dll --exclude=\*.exe"
	fi
}

#fatal_exit()
#{
#	${ECHO}
#	if [ -n ${1:+x} ] && ${ECHO} ${1}
#	exit 1
#}

# main()
get_build
if [ ${BUILD} = "Q" -o ${BUILD} = "q" ] ; then 
    exit
fi
get_source_host
get_delete
get_latest_or_success
set_path
check_destination
set_exclude_list

${ECHO}
${ECHO} "Retrieving "$BUILD_DESC" build from "$SOURCE_HOST

# rsync flags are 
# -r	recurse into directories
# -l	copy symlinks as symlinks
# -p	preserve permissions
# -t	preserve times
# -v	increase verbosity
# -z	compress file data during the transfer
# -u	(update) skip files that are newer on the receiver
# -c	(checksum) skip based on checksum, not mod-time & size
# ${DELETE_FILES} (--delete) delete extraneous files from dest dirs
# Note also that all the escaped quotes around the -e option and the :$SOURCE are mandatory - don't be tempted to remove them.
CMD="${SUDO} ${RSYNC} -rlptzuc --progress ${DELETE_FILES} ${EXCLUDE_LIST} -e \"ssh ${SSH_LOGIN}@${SOURCE_HOST}\" \":${SOURCE}\" ${DEST_DIR}"
eval ${CMD}
TRANSFER_RESULT=$?

if [ ${SYSTEM} != ${DARWIN} ] ; then #On a Mac/PC there's no Orc user
	${ECHO}
	${ECHO} "Changing owner and permissions of new Orc"
	cd $DEST_DIR/..
	CMD="${CHOWN} -R orc:orc ${DEST_DIR}"
	sudo ${CMD} || fatal_exit "Unable to update owner & group of ${DEST_DIR} - please check that you are in sudoers and manually update the owner & group of ${DEST_DIR}"
fi

case ${TRANSFER_RESULT} in
	0)	
	${ECHO}
	${ECHO} "Successfully installed "${BUILD_DESC}" build"
	;;

	23)
	${ECHO}
	${ECHO} "rsync reported \"nothing to transfer\"\c"
	;;

	*)
	${ECHO}
	${ECHO} "rsync retrieval of "${BUILD_DESC}" reported errors. Please re-run and check the script output. \c"
	;;

esac

exit 0
