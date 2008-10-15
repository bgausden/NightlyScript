#!/bin/sh 

PATH=/bin:/usr/bin:/usr/local/bin:/opt/sfw/bin
export PATH
id "orc" > /dev/null 2>&1
if [ $? -eq 0 ] ; then	
	ORC_USER_EXISTS=0
	SSH_LOGIN="orc@"
	SSH_IDENTITY="-i /etc/orc/.ssh/id_dsa"	
	SUDO="sudo"
else
	ORC_USER_EXISTS=1
	SSH_LOGIN=""
	SSH_IDENTITY=""
	SUDO=""
fi
SOURCE_HOST=linuxdev1
ROOT_DIR="/pub/static/common/applications/orc"
BUILD="NIGHTLY"
BUILD_TYPE="nightly"
if [ `uname -s`_ = "Linux_" ] ; then
	ECHO="/bin/echo -e"
	MAIL=`which mail`
else
	# Solaris and Darwin have mailx as standard
	ECHO=/bin/echo
	MAIL=`which mailx`
fi
# Only Orc.app and Sauron.app if on a Mac
#if [ `uname -s`_ = "Darwin_" ] ; then
	MAC_APPS_ONLY=0
#else
#	MAC_APPS_ONLY=1
#fi
# **OBSOLETE** As a general rule we'll be downloading something compiled yesterday
#DAY=`date +%d`
#DAY=`expr ${DAY} - 1`
#if [ `${ECHO} "${DAY}\c" | wc -c` -eq 1 ] ; then
#	DAY="0"${DAY}
#fi
#BUILD_DATE=`date +%Y-%m`"-"${DAY}
#BUILD_DATE=`date +%Y-%m-%d`
RSYNC=`which rsync`
APPS_ONLY="yes"
EXCLUDE_LIST=""

check_id()
{
    id | egrep '\(orc\).*\(.*\)' > /dev/null 2>&1
    if [ ! $? -eq 0 ] ; then
        # Not running this as orc - abort
        ${ECHO}
        ${ECHO} "This script must be run as the \"orc\" user. Aborting"
        exit
    fi
}

get_build()
{
    while
        ${ECHO}
        ${ECHO} "Download which build - 6.1, 7.1, (H)EAD or (Q)uit? <7.1> \c"
        read BUILD
        if [ ${BUILD}_ = "_" ] ; then
            BUILD="7.1"
         fi
        # grep for an acceptable response and convert to uppercase using tr(anslate)
        BUILD=`${ECHO} ${BUILD} | egrep '6\.1|7\.1|[Hh]|[Qq]' | tr '[:lower:]' '[:upper:]'`
        # if $BUILD is non-null, then test returns 1 and we exit the while loop
        test ${BUILD}"_" = "_"
    do
        ${ECHO} ""
    done
    if [ ${BUILD} = "H" ] ; then
        BUILD="HEAD"
    fi
}

get_build_date()
{
	SANE_DATE="yes"
	BUILD_DATE_TEMP=${BUILD_DATE}
	while
		${ECHO} 
		${ECHO} "Build from which date? <"${BUILD_DATE}"> \c" 
		read BUILD_DATE_TEMP 
		${ECHO} $BUILD_DATE_TEMP"_" | egrep '2004-(0[1-9]|1[0-2])-([0-2][1-9]|3[01])_|_' > /dev/null 2>&1
		if [ ! $? ] ; then
			SANE_DATE="no"
		else
			if [ ! ${BUILD_DATE_TEMP}_ = "_" ] ; then
				BUILD_DATE=${BUILD_DATE_TEMP}
			fi
		fi
		# This test is what continues or exits the while loop...
		test ${SANE_DATE} = "no"
	do
		${ECHO} ""
	done
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
CMD="${SUDO} ${RSYNC} -rlptvzuc ${DELETE_FILES} ${EXCLUDE_LIST} ${SSH_LOGIN}@${SOURCE_HOST}:\'"${SOURCE}"\' ${DEST_DIR}"
eval ${CMD}
TRANSFER_RESULT=$?

	${ECHO}
	${ECHO} "Changing owner and permissions of new Orc"
	cd $DEST_DIR/..
	sudo /usr/bin/chown -R orc:orc ${DEST_DIR}
	

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
