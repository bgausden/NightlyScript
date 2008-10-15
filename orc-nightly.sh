#!/bin/sh 

# Script to retrieve orc nightly builds via ssh/rsync

if [ `uname -s`_ = "Linux_" ] ; then
	ECHO="/bin/echo -e"
else
	ECHO="/bin/echo"
fi

fatal_exit()
{
	${ECHO}
	[ -n "${1}" ] && ${ECHO} ${1}". Aborting"
	exit 1
}

PATH=/usr/sbin:/bin:/usr/bin:/usr/local/bin:/opt/sfw/bin
export PATH

id "orc" > /dev/null 2>&1
if [ $? -eq 0 ] ; then	
	SSH_LOGIN="orc"
	SUDO="sudo"
else
	SSH_LOGIN=${USER}
	SUDO=""
fi

SOURCE_HOST=linuxdev1 #Default server to download from
ROOT_DIR="/pub/static/common/applications/orc" # Need this created on the source machine if doesn't exist.
DEFAULT_BUILD="7.1" # What to download if the user doesn't explictly choose a build to retrieve

# Only Orc.app and Sauron.app if on a Mac
if [ `uname -s`_ = "Darwin_" ] ; then
	MAC_APPS_ONLY=0
else
	MAC_APPS_ONLY=1
fi

RSYNC=`which rsync` 
[ -z ${RSYNC} ] && fatal_exit "Unable to locate rsync"
CHOWN=`which chown` 
[ -z ${CHOWN} ] && fatal_exit "Unable to locate chown"

EXCLUDE_LIST=""

get_build()
{
    while
        ${ECHO}
        #${ECHO} "Download which build - 6.1, 7.1, (H)EAD or (Q)uit? <${DEFAULT_BUILD}> \c"
        read -p "Download which build - 6.1, 7.1, (H)EAD or (Q)uit? <${DEFAULT_BUILD}> " -e BUILD
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
	SOURCE_HOST=linuxdev1
	${ECHO}
	${ECHO} "Sync with which server <"${SOURCE_HOST}"> \c"
	read SOURCE_HOST
	[ -z ${SOURCE_HOST} ] && SOURCE_HOST=linuxdev1
}


set_path()
# Stripped out the rolling build support completely as unused.
{
	case ${BUILD} in
		6.1)
			ROOT_DIR="/pub/builds/nightly/Orc-6-1/success/release/orc"
			BUILD_DESC="Nightly 6.1"
			DEST_DIR="/orcreleases/orc-6.1"
		;;
		7.1)
			ROOT_DIR="/pub/builds/nightly/Orc-7-1/success/release/orc"
			BUILD_DESC="Nightly 7.1"
			DEST_DIR="/orcreleases/orc-7.1"
		;;
		HEAD)
			ROOT_DIR="/pub/builds/nightly/HEAD/success/release/orc"
			BUILD_DESC="Nightly HEAD"
			DEST_DIR="/orcreleases/orc-HEAD"
		;;
	esac
	SANE_ANSWER="yes"
	SOURCE=${ROOT_DIR}
	if [ ${MAC_APPS_ONLY} -eq 0 ] ; then
		DEST_DIR="/Applications/Orc-"${BUILD}
		SOURCE="${SOURCE}/apps/Orc.app ${SOURCE}/apps/Sauron.app ${SOURCE}/lib/liquidator.jar ${SOURCE}/lib/lprofiler.jar ${SOURCE}/apps/Documentation/OrcTraderManual.pdf ${SOURCE}/apps/Documentation/ReleaseNotes.pdf ${SOURCE}/apps/Documentation/MarketLinks.pdf ${SOURCE}/doc ${SOURCE}/sdk/liquidator/Documentation ${SOURCE}/sdk/liquidator/Examples ${SOURCE}/sdk/op"
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
	EXCLUDE_LIST="--exclude=\*/CVS/ --exclude=arch/i386-pc-cygwin/ --exclude=i386-unknown-linux"
	EXCLUDE_LIST=${EXCLUDE_LIST}" --exclude=\*apple-darwin/ --exclude=\*sparc\* --exclude=\*-gcc\* --exclude=x86_64-sun-solaris/"
	EXCLUDE_LIST=${EXCLUDE_LIST}" --exclude=x86_64-unknown-linux-gcc --exclude=apps/httpd\*"
	if [ ${MAC_APPS_ONLY} -eq 0 ] ; then
		EXCLUDE_LIST=${EXCLUDE_LIST}" --exclude=\*.dll --exclude=\*.exe"
	fi
}

fatal_exit()
{
	${ECHO}
	[ -n $1 ] && ${ECHO} ${1}
	exit 1
}

# main()
get_build
if [ ${BUILD} = "Q" -o ${BUILD} = "q" ] ; then 
    exit
fi
get_source_host
get_delete
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
#cd ${DEST_DIR}
CMD="${SUDO} ${RSYNC} -rlptzuc --progress ${DELETE_FILES} ${EXCLUDE_LIST} -e \"ssh ${SSH_LOGIN}@${SOURCE_HOST}\" \":${SOURCE}\" ${DEST_DIR}"
eval ${CMD}
TRANSFER_RESULT=$?

if [ ! ${MAC_APPS_ONLY} ] ; then #On a Mac/PC there's no Orc user
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
