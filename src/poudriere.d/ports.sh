#!/bin/sh

SCRIPTPATH=`realpath $0`
SCRIPTPREFIX=`dirname ${SCRIPTPATH}`
. ${SCRIPTPREFIX}/common.sh

# test if there is any args
usage() {
	echo "poudriere ports [parameters] [options]

Parameters:
    -c            -- create a portstree
    -d            -- delete a portstree
    -u            -- update a portstree
    -l            -- lists all available portstrees
    -q            -- quiet (remove the header in list)

Options:
    -F            -- when used with -c, only create the needed ZFS
                     filesystems and directories, but do not populate
                     them.
    -p name       -- specifies the name of the portstree we workon . If not
                     specified, work on a portstree called \"default\".
    -f fs         -- FS name (tank/jails/myjail) if fs is \"none\" then do not
                     create on zfs
    -M mountpoint -- mountpoint
    -m method     -- when used with -c, specify the method used to update the
                     tree by default it is portsnap, possible usage are
                     \"csup\", \"portsnap\", \"svn\", \"svn+http\", \"svn+ssh\""

	exit 1
}

CREATE=0
FAKE=0
UPDATE=0
DELETE=0
LIST=0
QUIET=0
while getopts "cFudlp:qf:M:m" FLAG; do
	case "${FLAG}" in
		c)
			CREATE=1
			;;
		F)
			FAKE=1
			;;
		u)
			UPDATE=1
			;;
		p)
			PTNAME=${OPTARG}
			;;
		d)
			DELETE=1
			;;
		l)
			LIST=1
			;;
		q)
			QUIET=1
			;;
		f)
			PTFS=${OPTARG}
			;;
		M)
			PTMNT=${OPTARG}
			;;
		m)
			METHOD=${OPTARG}
			;;
		*)
			usage
		;;
	esac
done

[ $(( CREATE + UPDATE + DELETE + LIST )) -lt 1 ] && usage

METHOD=${METHOD:-portsnap}
PTNAME=${PTNAME:-default}

case ${METHOD} in
csup)
	[ -z ${CSUP_HOST} ] && err 2 "CSUP_HOST has to be defined in the configuration to use csup"
	;;
portsnap);;
svn+http);;
svn+ssh);;
svn);;
git);;
*) usage;;
esac

if [ ${LIST} -eq 1 ]; then
	format='%-20s %-10s %s\n'
	[ $QUIET -eq 0 ] && \
		printf "${format}" "PORTSTREE" "METHOD" "PATH"
	porttree_list | while read ptname ptmethod ptpath; do
		printf "${format}" ${ptname} ${ptmethod} ${ptpath}
	done
else
	test -z "${PTNAME}" && usage
fi
if [ ${CREATE} -eq 1 ]; then
	# test if it already exists
	porttree_exists ${PTNAME} && err 2 "The ports tree ${PTNAME} already exists"
	: ${PTMNT="${BASEFS:=/usr/local${ZROOTFS}}/ports/${PTNAME}"}
	: ${PTFS="${ZPOOL}${ZROOTFS}/ports/${PTNAME}"}
	porttree_create_zfs ${PTNAME} ${PTMNT} ${PTFS}
	if [ $FAKE -eq 0 ]; then
		case ${METHOD} in
		csup)
			echo "/!\ WARNING /!\ csup is deprecated and will soon be dropped"
			mkdir ${PTMNT}/db
			echo "*default prefix=${PTMNT}
*default base=${PTMNT}/db
*default release=cvs tag=.
*default delete use-rel-suffix
ports-all" > ${PTMNT}/csup
			csup -z -h ${CSUP_HOST} ${PTMNT}/csup || {
				if [ ${PTFS} != "none" ]; then
					zfs destroy ${PTFS}
				else
					rm -rf ${PTMNT}
					sed -i "" "s/${PTNAME}/d" \
						${POUDRIERED}/portstrees
				fi
				err 1 " Fail"
			}
			;;
		portsnap)
			mkdir ${PTMNT}/snap
			msg "Extracting portstree \"${PTNAME}\"..."
			mkdir ${PTMNT}/ports
			/usr/sbin/portsnap -d ${PTMNT}/snap -p ${PTMNT}/ports fetch extract || \
			/usr/sbin/portsnap -d ${PTMNT}/snap -p ${PTMNT}/ports fetch extract || \
			{
				if [ ${PTFS} != "none" ]; then
					zfs destroy ${PTFS}
				else
					rm -rf ${PTMNT}
					sed -i "" "s/${PTNAME}/d" \
						${POUDRIERED}/portstrees
				fi
				err 1 " Fail"
			}
			;;
		svn*)
			case ${METHOD} in
			svn+http) proto="http" ;;
			svn+ssh) proto="svn+ssh" ;;
			svn) proto="svn" ;;
			esac

			msg_n "Checking out the ports tree..."
			svn -q co ${proto}://${SVN_HOST}/ports/head \
				${PTMNT} || {
				if [ ${PTFS} != "none" ]; then
					zfs destroy ${PTFS}
				else
					rm -rf ${PTMNT}
					sed -i "" "s/${PTNAME}/d" \
						${POUDRIERED}/portstrees
				fi
				err 1 " Fail"
			}
			echo " done"
			;;
		git)
			msg "Cloning the ports tree"
			git clone ${GIT_URL} ${PTMNT} || {
				if [ ${PTFS} != "none" ]; then
					zfs destroy ${PTFS}
				else
					rm -rf ${PTMNT}
					sed -i "" "/${PTNAME}/d" \
						${POUDRIERED}/portstrees
				fi
			}
			echo " done"
			;;
		esac
		pzset method ${METHOD}
		sed -i "" "s/__METHOD__/${METHOD}/g" ${POUDRIERED}/portstrees
	fi
fi

if [ ${DELETE} -eq 1 ]; then
	porttree_exists ${PTNAME} || err 2 "No such ports tree ${PTNAME}"
	PTMNT=$(porttree_get_base ${PTNAME})
	[ -d "${PTMNT}/ports" ] && PORTSMNT="${PTMNT}/ports"
	/sbin/mount -t nullfs | /usr/bin/grep -q "${PORTSMNT:-${PTMNT}} on" \
		&& err 1 "Ports tree \"${PTNAME}\" is currently mounted and being used."
	msg "Deleting portstree \"${PTNAME}\""
	PTFS=$(porttree_get_fs ${PTNAME})
	if [ -n "${PTFS}" ]; then
		zfs destroy -r ${PTFS}
	else
		rm -rf ${PTMNT}
		sed -i "" "/${PTNAME}/d" \
			${POUDRIERED}/portstrees
	fi
fi

if [ ${UPDATE} -eq 1 ]; then
	porttree_exists ${PTNAME} || err 2 "No such ports tree ${PTNAME}"
	METHOD=$(porttree_get_method ${PTNAME})
	PTMNT=$(porttree_get_base ${PTNAME})
	[ -d "${PTMNT}/ports" ] && PORTSMNT="${PTMNT}/ports"
	/sbin/mount -t nullfs | /usr/bin/grep -q "${PORTSMNT:-${PTMNT}} on" \
		&& err 1 "Ports tree \"${PTNAME}\" is currently mounted and being used."
	msg "Updating portstree \"${PTNAME}\""
	if [ ${METHOD} = "-" ]; then
		METHOD=portsnap
		pzset method ${METHOD}
	fi
	case ${METHOD} in
	csup)
		echo "/!\ WARNING /!\ csup is deprecated and will soon be dropped"
		[ -z ${CSUP_HOST} ] && err 2 "CSUP_HOST has to be defined in the configuration to use csup"
		mkdir -p ${PTMNT}/db
		echo "*default prefix=${PTMNT}
*default base=${PTMNT}/db
*default release=cvs tag=.
*default delete use-rel-suffix
ports-all" > ${PTMNT}/csup
		csup -z -h ${CSUP_HOST} ${PTMNT}/csup
		;;
	portsnap|"")
		PSCOMMAND=fetch
		[ -t 0 ] || PSCOMMAND=cron
		/usr/sbin/portsnap -d ${PTMNT}/snap -p ${PORTSMNT} ${PSCOMMAND} update
		;;
	svn*)
		msg_n "Updating the ports tree..."
		svn -q update ${PORTSMNT:-${PTMNT}}
		echo " done"
		;;
	git)
		msg "Pulling from ${GIT_URL}"
		cd ${PORTSMNT:-${PTMNT}} && git pull
		echo " done"
		;;
	*)
		err 1 "Undefined upgrade method"
		;;
	esac

	date +%s > ${PORTSMNT:-${PTMNT}}/.poudriere.stamp
fi
