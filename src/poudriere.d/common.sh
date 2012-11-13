#!/bin/sh

# zfs namespace
NS="poudriere"
IPS="$(sysctl -n kern.features.inet 2>/dev/null || (sysctl -n net.inet 1>/dev/null 2>&1 && echo 1) || echo 0)$(sysctl -n kern.features.inet6 2>/dev/null || (sysctl -n net.inet6 1>/dev/null 2>&1 && echo 1) || echo 0)"

dir_empty() {
	find $1 -maxdepth 0 -empty
}

err() {
	if [ $# -ne 2 ]; then
		err 1 "err expects 2 arguments: exit_number \"message\""
	fi
	local err_msg="Error: $2"
	msg "${err_msg}" >&2
	[ -n "${MY_JOBID}" ] && job_msg "${err_msg}"
	exit $1
}

msg_n() { echo -n "====>> $1"; }
msg() { echo "====>> $1"; }
msg_verbose() {
	[ ${VERBOSE:-0} -gt 0 ] || return 0
	msg "$1"
}

msg_debug() {
	[ ${VERBOSE:-0} -gt 1 ] || return 0

	msg "DEBUG: $1" >&2
}

job_msg() {
	[ -n "${MY_JOBID}" ] || return 0
	msg "[${MY_JOBID}] $1" >&5
}

job_msg_verbose() {
	[ -n "${MY_JOBID}" ] || return 0
	msg_verbose "[${MY_JOBID}] $1" >&5
}

eargs() {
	case $# in
	0) err 1 "No arguments expected" ;;
	1) err 1 "1 argument expected: $1" ;;
	*) err 1 "$# arguments expected: $*" ;;
	esac
}

log_start() {
	local logfile=$1

	# Make sure directory exists
	mkdir -p ${logfile%/*}

	exec 3>&1 4>&2
	[ ! -e ${logfile}.pipe ] && mkfifo ${logfile}.pipe
	tee ${logfile} < ${logfile}.pipe >&3 &
	export tpid=$!
	exec > ${logfile}.pipe 2>&1

	# Remove fifo pipe file right away to avoid orphaning it.
	# The pipe will continue to work as long as we keep
	# the FD open to it.
	rm -f ${logfile}.pipe
}

log_path() {
	echo "${LOGS}/${POUDRIERE_BUILD_TYPE}/${JAILNAME%-job-*}/${PTNAME}${SETNAME}"
}

buildlog_start() {
	local portdir=$1

	echo "build started at $(date)"
	echo "port directory: ${portdir}"
	echo "building for: $(injail uname -rm)"
	echo "maintained by: $(injail make -C ${portdir} maintainer)"
	echo "Makefile ident: $(injail ident ${portdir}/Makefile|sed -n '2,2p')"

	echo "---Begin Environment---"
	injail env ${PKGENV} ${PORT_FLAGS}
	echo "---End Environment---"
	echo ""
	echo "---Begin OPTIONS List---"
	injail make -C ${portdir} showconfig
	echo "---End OPTIONS List---"
}

buildlog_stop() {
	local portdir=$1

	echo "build of ${portdir} ended at $(date)"
}

log_stop() {
	if [ -n "${tpid}" ]; then
		exec 1>&3 3>&- 2>&4 4>&-
		wait $tpid
		unset tpid
	fi
}

zget() {
	[ $# -ne 1 ] && eargs property
	zfs get -H -o value ${NS}:${1} ${JAILFS}
}

zset() {
	[ $# -ne 2 ] && eargs property value
	zfs set ${NS}:$1="$2" ${JAILFS}
}

pzset() {
	[ $# -ne 2 ] && eargs property value
	zfs set ${NS}:$1="$2" ${PTFS}
}

pzget() {
	[ $# -ne 1 ] && eargs property
	zfs get -H -o value ${NS}:${1} ${PTFS}
}

sig_handler() {
	trap - SIGTERM SIGKILL
	# Ignore SIGINT while cleaning up
	trap '' SIGINT
	err 1 "Signal caught, cleaning up and exiting"
}

exit_handler() {
	# Avoid recursively cleaning up here
	trap - EXIT SIGTERM SIGKILL
	# Ignore SIGINT while cleaning up
	trap '' SIGINT
	[ ${STATUS} -eq 1 ] && cleanup
	[ -n ${CLEANUP_HOOK} ] && ${CLEANUP_HOOK}
}

siginfo_handler() {
	if [ "${POUDRIERE_BUILD_TYPE}" != "bulk" ]; then
		return 0;
	fi
	local status=$(zget status)
	local nbb=$(zget stats_built|sed -e 's/ //g')
	local nbf=$(zget stats_failed|sed -e 's/ //g')
	local nbi=$(zget stats_ignored|sed -e 's/ //g')
	local nbs=$(zget stats_skipped|sed -e 's/ //g')
	local nbq=$(zget stats_queued|sed -e 's/ //g')
	local ndone=$((nbb + nbf + nbi + nbs))
	local queue_width=2
	local j status

	if [ ${nbq} -gt 9999 ]; then
		queue_width=5
	elif [ ${nbq} -gt 999 ]; then
		queue_width=4
	elif [ ${nbq} -gt 99 ]; then
		queue_width=3
	fi

	printf "[${JAILNAME}] [${status}] [%0${queue_width}d/%0${queue_width}d] Built: %-${queue_width}d Failed: %-${queue_width}d  Ignored: %-${queue_width}d  Skipped: %-${queue_width}d  \n" \
	  ${ndone} ${nbq} ${nbb} ${nbf} ${nbi} ${nbs}

	# Skip if stopping or starting jobs
	if [ -n "${JOBS}" -a "${status#starting_jobs:}" = "${status}" -a "${status}" != "stopping_jobs:" ]; then
		for j in ${JOBS}; do
			# Ignore error here as the zfs dataset may not be cloned yet.
			status=$(JAILFS=${JAILFS}/build/${j} zget status 2>/dev/null || :)
			# Skip builders not started yet
			[ -z "${status}" ] && continue
			# Hide idle workers
			[ "${status}" = "idle:" ] && continue
			echo -e "\t[${j}]: ${status}"
		done
	fi
}

jail_exists() {
	[ $# -ne 1 ] && eargs jailname
	zfs list -rt filesystem -H -o ${NS}:type,${NS}:name ${ZPOOL}${ZROOTFS} | \
		awk -v n=$1 'BEGIN { ret = 1 } $1 == "rootfs" && $2 == n { ret = 0; } END { exit ret }' && return 0
	return 1
}

jail_runs() {
	[ $# -ne 0 ] && eargs
	jls -qj ${JAILNAME} name > /dev/null 2>&1 && return 0
	return 1
}

jail_get_base() {
	[ $# -ne 1 ] && eargs jailname
	zfs list -rt filesystem -s name -H -o ${NS}:type,${NS}:name,mountpoint ${ZPOOL}${ZROOTFS} | \
		awk -v n=$1 '$1 == "rootfs" && $2 == n  { print $3 }' | head -n 1
}

jail_get_version() {
	[ $# -ne 1 ] && eargs jailname
	zfs list -rt filesystem -s name -H -o ${NS}:type,${NS}:name,${NS}:version ${ZPOOL}${ZROOTFS} | \
		awk -v n=$1 '$1 == "rootfs" && $2 == n { print $3 }' | head -n 1
}

jail_get_fs() {
	[ $# -ne 1 ] && eargs jailname
	zfs list -rt filesystem -s name -H -o ${NS}:type,${NS}:name,name ${ZPOOL}${ZROOTFS} | \
		awk -v n=$1 '$1 == "rootfs" && $2 == n { print $3 }' | head -n 1
}

porttree_list() {
	local name method mntpoint n format
	# Combine local ZFS and manual list
	zfs list -t filesystem -H -o ${NS}:type,${NS}:name,${NS}:method,mountpoint | \
		awk '$1 == "ports" { print $2 " " $3 " " $4 }'
	if [ -f "${POUDRIERED}/portstrees" ]; then
		# Validate proper format
		format="Format expected: NAME PATH"
		n=0
		while read name mntpoint; do
			n=$((n + 1))
			[ -z "${name###*}" ] && continue # Skip comments
			[ -n "${name%%/*}" ] || \
				err 1 "$(realpath ${POUDRIERED}/portstrees):${n}: Invalid name '${name}'. ${format}"
			[ -n "${mntpoint}" ] || \
				err 1 "$(realpath ${POUDRIERED}/portstrees):${n}: Missing path for '${name}'. ${format}"
			[ -z "${mntpoint%%/*}" ] || \
				err 1 "$(realpath ${POUDRIERED}/portstrees):${n}: Invalid path '${mntpoint}' for '${name}'. ${format}"
			echo "${name} manual ${mntpoint}"
		done < ${POUDRIERED}/portstrees
	fi
	# Outputs: name method mountpoint
}

porttree_get_method() {
	[ $# -ne 1 ] && eargs portstree_name
	porttree_list | awk -v portstree_name=$1 '$1 == portstree_name {print $2}'
}

porttree_exists() {
	[ $# -ne 1 ] && eargs portstree_name
	porttree_list |
		awk -v portstree_name=$1 '
		BEGIN { ret = 1 }
		$1 == portstree_name {ret = 0; }
		END { exit ret }
		' && return 0
	return 1
}

porttree_get_base() {
	[ $# -ne 1 ] && eargs portstree_name
	porttree_list | awk -v portstree_name=$1 '$1 == portstree_name { print $3 }'
}

porttree_get_fs() {
	[ $# -ne 1 ] && eargs portstree_name
	zfs list -t filesystem -H -o ${NS}:type,${NS}:name,name | \
		awk -v n=$1 '$1 == "ports" && $2 == n { print $3 }'
}

get_data_dir() {
	local data
	if [ -n "${POUDRIERE_DATA}" ]; then
		echo ${POUDRIERE_DATA}
		return
	fi
	data=$(zfs list -rt filesystem -H -o ${NS}:type,mountpoint ${ZPOOL}${ZROOTFS} | awk '$1 == "data" { print $2 }' | head -n 1)
	if [ -n "${data}" ]; then
		echo $data
		return
	fi
	zfs create -p -o ${NS}:type=data \
		-o mountpoint=${BASEFS}/data \
		${ZPOOL}${ZROOTFS}/data
	echo "${BASEFS}/data"
}

fetch_file() {
	[ $# -ne 2 ] && eargs destination source
	fetch -p -o $1 $2 || fetch -p -o $1 $2
}

jail_create_zfs() {
	[ $# -ne 5 ] && eargs name version arch mountpoint fs
	local name=$1
	local version=$2
	local arch=$3
	local mnt=$( echo $4 | sed -e "s,//,/,g")
	local fs=$5
	msg_n "Creating ${name} fs..."
	zfs create -p \
		-o ${NS}:type=rootfs \
		-o ${NS}:name=${name} \
		-o ${NS}:version=${version} \
		-o ${NS}:arch=${arch} \
		-o mountpoint=${mnt} ${fs} || err 1 " Fail" && echo " done"
}

jrun() {
	[ $# -ne 1 ] && eargs network
	local network=$1
	local ipargs
	if [ ${network} -eq 0 ]; then
		case $IPS in
		01) ipargs="ip6.addr=::1" ;;
		10) ipargs="ip4.addr=127.0.0.1" ;;
		11) ipargs="ip4.addr=127.0.0.1 ip6.addr=::1" ;;
		esac
	else
		case $IPS in
		01) ipargs="ip6=inherit" ;;
		10) ipargs="ip4=inherit" ;;
		11) ipargs="ip4=inherit ip6=inherit" ;;
		esac
	fi
	jail -c persist name=${JAILNAME} ${ipargs} path=${JAILMNT} \
		host.hostname=${JAILNAME} allow.sysvipc allow.mount \
		allow.socket_af allow.raw_sockets allow.chflags
}

do_jail_mounts() {
	[ $# -ne 1 ] && eargs should_mkdir
	local should_mkdir=$1
	local arch=$(zget arch)

	# Only do this when starting the master jail, clones will already have the dirs
	if [ ${should_mkdir} -eq 1 ]; then
		mkdir -p ${JAILMNT}/proc
	fi

	mount -t devfs devfs ${JAILMNT}/dev
	mount -t fdescfs fdesc ${JAILMNT}/dev/fd
	mount -t procfs proc ${JAILMNT}/proc

	if [ -z "${NOLINUX}" ]; then
		if [ "${arch}" = "i386" -o "${arch}" = "amd64" ]; then
			if [ ${should_mkdir} -eq 1 ]; then
				mkdir -p ${JAILMNT}/compat/linux/proc
				mkdir -p ${JAILMNT}/compat/linux/sys
			fi
			mount -t linprocfs linprocfs ${JAILMNT}/compat/linux/proc
#			mount -t linsysfs linsysfs ${JAILMNT}/compat/linux/sys
		fi
	fi
}

use_options() {
	[ $# -ne 2 ] && eargs optionsdir verbose
	local optionsdir="$(realpath "$1")"
	local verbose="$2"

	[ ${verbose} -eq 1 ] && msg "Mounting /var/db/ports from: ${optionsdir}"
	mount -t nullfs ${optionsdir} ${JAILMNT}/var/db/ports || err 1 "Failed to mount OPTIONS directory"
}

do_portbuild_mounts() {
	[ $# -ne 1 ] && eargs should_mkdir
	local should_mkdir=$1

	# Only do this when starting the master jail, clones will already have the dirs
	if [ ${should_mkdir} -eq 1 ]; then
		mkdir -p ${PORTSDIR}/packages
		mkdir -p ${PKGDIR}/All
		mkdir -p ${PORTSDIR}/distfiles
		if [ -d "${CCACHE_DIR:-/nonexistent}" ]; then
			mkdir -p ${JAILMNT}${CCACHE_DIR} || err 1 "Failed to create ccache directory "
			msg "Mounting ccache from: ${CCACHE_DIR}"
			export CCACHE_DIR
			export WITH_CCACHE_BUILD=yes
		fi
		# Check for invalid options-JAILNAME created by bad options.sh
		[ -d ${POUDRIERED}/options-${JAILNAME%-job-*} ] && err 1 "Please move your options-${JAILNAME%-job-*} to ${JAILNAME%-job-*}-options"

		msg "Mounting packages from: ${PKGDIR}"
	fi

	mount -t nullfs ${PORTSDIR} ${JAILMNT}/usr/ports || err 1 "Failed to mount the ports directory "
	mount -t nullfs ${PKGDIR} ${JAILMNT}/usr/ports/packages || err 1 "Failed to mount the packages directory "

	if [ -d "${DISTFILES_CACHE:-/nonexistent}" ]; then
		mount -t nullfs ${DISTFILES_CACHE} ${JAILMNT}/usr/ports/distfiles || err 1 "Failed to mount the distfile directory"
	fi
	[ -n "${MFSSIZE}" ] && mdmfs -M -S -o async -s ${MFSSIZE} md ${JAILMNT}/wrkdirs
	[ -n "${USE_TMPFS}" ] && mount -t tmpfs tmpfs ${JAILMNT}/wrkdirs

	# Order is JAILNAME-SETNAME, then SETNAME, then JAILNAME, then default.
	if [ -n "${SETNAME}" -a -d ${POUDRIERED}/${JAILNAME%-job-*}${SETNAME}-options ]; then
		use_options ${POUDRIERED}/${JAILNAME%-job-*}${SETNAME}-options ${should_mkdir}
	elif [ -d ${POUDRIERED}/${SETNAME#-}-options ]; then
		use_options ${POUDRIERED}/${SETNAME#-}-options ${should_mkdir}
	elif [ -d ${POUDRIERED}/${JAILNAME%-job-*}-options ]; then
		use_options ${POUDRIERED}/${JAILNAME%-job-*}-options ${should_mkdir}
	elif [ -d ${POUDRIERED}/options ]; then
		use_options ${POUDRIERED}/options ${should_mkdir}
	fi

	if [ -d "${CCACHE_DIR:-/nonexistent}" ]; then
		# Mount user supplied CCACHE_DIR into /var/cache/ccache
		mount -t nullfs ${CCACHE_DIR} ${JAILMNT}${CCACHE_DIR} || err 1 "Failed to mount the ccache directory "
	fi
}

jail_start() {
	[ $# -ne 0 ] && eargs
	local arch=$(zget arch)
	local NEEDFS="nullfs procfs"
	if [ -z "${NOLINUX}" ]; then
		if [ "${arch}" = "i386" -o "${arch}" = "amd64" ]; then
			NEEDFS="${NEEDFS} linprocfs linsysfs"
			sysctl -n compat.linux.osrelease >/dev/null 2>&1 || kldload linux
		fi
	fi
	[ -n "${USE_TMPFS}" ] && NEEDFS="${NEEDFS} tmpfs"
	for fs in ${NEEDFS}; do
		lsvfs $fs >/dev/null 2>&1 || kldload $fs
	done
	jail_exists ${JAILNAME} || err 1 "No such jail: ${JAILNAME}"
	jail_runs && err 1 "jail already running: ${JAILNAME}"
	zset status "start:"
	zfs destroy -r ${JAILFS}/build 2>/dev/null || :
	zfs rollback -R ${JAILFS}@clean

	msg "Mounting system devices for ${JAILNAME}"
	do_jail_mounts 1

	test -n "${RESOLV_CONF}" && cp -v "${RESOLV_CONF}" "${JAILMNT}/etc/"
	msg "Starting jail ${JAILNAME}"
	jrun 0
	# Only set STATUS=1 if not turned off
	# jail -s should not do this or jail will stop on EXIT
	[ ${SET_STATUS_ON_START-1} -eq 1 ] && export STATUS=1
}

jail_stop() {
	[ $# -ne 0 ] && eargs
	local mnt
	jail_runs || err 1 "No such jail running: ${JAILNAME%-job-*}"
	zset status "stop:"

	jail -r ${JAILNAME%-job-*} >/dev/null
	# Shutdown all builders
	if [ ${PARALLEL_JOBS} -ne 0 ]; then
		# - here to only check for unset, {start,stop}_builders will set this to blank if already stopped
		for j in ${JOBS-$(jot -w %02d ${PARALLEL_JOBS})}; do
			jail -r ${JAILNAME%-job-*}-job-${j} >/dev/null 2>&1 || :
		done
	fi
	msg "Umounting file systems"
	mnt=`realpath ${MASTERMNT:-${JAILMNT}}`
	mount | awk -v mnt="${mnt}/" 'BEGIN{ gsub(/\//, "\\\/", mnt); } { if ($3 ~ mnt && $1 !~ /\/dev\/md/ ) { print $3 }}' |  sort -r | xargs umount -f || :

	if [ -n "${MFSSIZE}" ]; then
		# umount the ${JAILMNT}/build/$jobno/wrkdirs
		mount | grep "/dev/md.*${mnt}/build" | while read mntpt; do
			local dev=`echo $mntpt | awk '{print $1}'`
			if [ -n "$dev" ]; then
				umount $dev
				mdconfig -d -u $dev
			fi
		done
		# umount the $JAILMNT/wrkdirs
		local dev=`mount | grep "/dev/md.*${mnt}" | awk '{print $1}'`
		if [ -n "$dev" ]; then
			umount $dev
			mdconfig -d -u $dev
		fi
	fi
	zfs rollback -R ${JAILFS%/build/*}@clean
	zset status "idle:"
	export STATUS=0
}

porttree_create_zfs() {
	[ $# -ne 3 ] && eargs name mountpoint fs
	local name=$1
	local mnt=$( echo $2 | sed -e 's,//,/,g')
	local fs=$3
	msg_n "Creating ${name} fs..."
	zfs create -p \
		-o atime=off \
		-o compression=off \
		-o mountpoint=${mnt} \
		-o ${NS}:type=ports \
		-o ${NS}:name=${name} \
		${fs} || err 1 " Fail" && echo " done"
}

cleanup() {
	[ -n "${CLEANED_UP}" ] && return 0
	msg "Cleaning up"
	# If this is a builder, don't cleanup, the master will handle that.
	if [ -n "${MY_JOBID}" ]; then
		[ -n "${PKGNAME}" ] && clean_pool ${PKGNAME} 1 || :
		return 0

	fi
	# Prevent recursive cleanup on error
	if [ -n "${CLEANING_UP}" ]; then
		echo "Failure cleaning up. Giving up." >&2
		return
	fi
	export CLEANING_UP=1
	[ -z "${JAILNAME%-job-*}" ] && err 2 "Fail: Missing JAILNAME"
	log_stop

	# Kill all children - this does NOT recurse, so orphans can still
	# occur. This is just to avoid requiring pid files for parallel_run
	for pid in $(jobs -p); do
		kill ${pid} 2>/dev/null || :
	done

	if [ -d ${MASTERMNT:-${JAILMNT}}/poudriere/var/run ]; then
		for pid in ${MASTERMNT:-${JAILMNT}}/poudriere/var/run/*.pid; do
			# Ensure there is a pidfile to read or break
			[ "${pid}" = "${MASTERMNT:-${JAILMNT}}/poudriere/var/run/*.pid" ] && break
			pkill -15 -F ${pid} >/dev/null 2>&1 || :
		done
	fi
	wait

	zfs destroy -r ${JAILFS%/build/*}/build 2>/dev/null || :
	zfs destroy -r ${JAILFS%/build/*}@prepkg 2>/dev/null || :
	zfs destroy -r ${JAILFS%/build/*}@preinst 2>/dev/null || :
	jail_stop
	export CLEANED_UP=1
}

injail() {
	jexec -U root ${JAILNAME} $@
}

sanity_check_pkgs() {
	local ret=0
	local depfile
	[ ! -d ${PKGDIR}/All ] && return $ret
	[ -n "$(dir_empty ${PKGDIR}/All)" ] && return $ret
	for pkg in ${PKGDIR}/All/*.${PKG_EXT}; do
		# Check for non-empty directory with no packages in it
		[ "${pkg}" = "${PKGDIR}/All/*.${PKG_EXT}" ] && break
		depfile=$(deps_file ${pkg})
		while read dep; do
			if [ ! -e "${PKGDIR}/All/${dep}.${PKG_EXT}" ]; then
				ret=1
				msg "Deleting ${pkg}: missing dependencies"
				delete_pkg ${pkg}
				break
			fi
		done < "${depfile}"
	done

	return $ret
}

# Build+test port and return on first failure
build_port() {
	[ $# -ne 1 ] && eargs portdir
	local portdir=$1
	local port=${portdir##/usr/ports/}
	local targets="check-config fetch checksum extract patch configure build run-depends install package ${PORTTESTING:+deinstall}"

	for phase in ${targets}; do
		zset status "${phase}:${port}"
		job_msg_verbose "Status for build ${port}: ${phase}"
		if [ "${phase}" = "fetch" ]; then
			jail -r ${JAILNAME} >/dev/null
			jrun 1
		fi
		[ "${phase}" = "install" -a $ZVERSION -ge 28 ] && zfs snapshot ${JAILFS}@preinst
		if [ "${phase}" = "deinstall" ]; then
			msg "Checking shared library dependencies"
			if [ ${PKGNG} -eq 0 ]; then
				PLIST="/var/db/pkg/${PKGNAME}/+CONTENTS"
				grep -v "^@" ${JAILMNT}${PLIST} | \
					sed -e "s,^,${PREFIX}/," | \
					xargs injail ldd 2>&1 | \
					grep -v "not a dynamic executable" | \
					awk ' /=>/{ print $3 }' | sort -u
			else
				injail pkg query "%Fp" ${PKGNAME} | \
					xargs injail ldd 2>&1 | \
					grep -v "not a dynamic executable" | \
					awk '/=>/ { print $3 }' | sort -u
			fi
		fi

		print_phase_header ${phase}
		injail env ${PKGENV} ${PORT_FLAGS} make -C ${portdir} ${phase} || return 1
		print_phase_footer

		if [ "${phase}" = "checksum" ]; then
			jail -r ${JAILNAME} >/dev/null
			jrun 0
		fi
		if [ "${phase}" = "deinstall" ]; then
			msg "Checking for extra files and directories"
			PREFIX=`injail make -C ${portdir} -VPREFIX`
			zset status "leftovers:${port}"
			if [ $ZVERSION -lt 28 ]; then
				find ${jailbase}${PREFIX} ! -type d | \
					sed -e "s,^${jailbase}${PREFIX}/,," | sort

				find ${jailbase}${PREFIX}/ -type d | sed "s,^${jailbase}${PREFIX}/,," | sort > ${jailbase}${PREFIX}.PLIST_DIRS.after
				comm -13 ${jailbase}${PREFIX}.PLIST_DIRS.before ${jailbase}${PREFIX}.PLIST_DIRS.after | sort -r | awk '{ print "@dirrmtry "$1}'
			else
				local portname=$(injail make -C ${portdir} -VPORTNAME)
				local add=$(mktemp ${jailbase}/tmp/add.XXXXXX)
				local add1=$(mktemp ${jailbase}/tmp/add1.XXXXXX)
				local del=$(mktemp ${jailbase}/tmp/del.XXXXXX)
				local del1=$(mktemp ${jailbase}/tmp/del1.XXXXXX)
				local mod=$(mktemp ${jailbase}/tmp/mod.XXXXXX)
				local mod1=$(mktemp ${jailbase}/tmp/mod1.XXXXXX)
				local die=0
				zfs diff -FH ${JAILFS}@preinst ${JAILFS} | \
					while read mod type path; do
					local ppath
					ppath=`echo "$path" | sed -e "s,^${JAILMNT},," -e "s,^${PREFIX}/,," -e "s,^share/${portname},%%DATADIR%%," -e "s,^etc/${portname},%%ETCDIR%%,"`
					case "$ppath" in
					/var/db/pkg/*) continue;;
					/var/run/*) continue;;
					/wrkdirs/*) continue;;
					/tmp/*) continue;;
					share/nls/POSIX) continue;;
					share/nls/en_US.US-ASCII) continue;;
					/var/db/fontconfig/*) continue;;
					/var/log/*) continue;;
					/var/mail/*) continue;;
					${HOME}/*) continue;;
					/etc/spwd.db) continue;;
					/etc/pwd.db) continue;;
					/etc/group) continue;;
					/etc/make.conf) continue;;
					/etc/passwd) continue;;
					/etc/master.passwd) continue;;
					/etc/shells) continue;;
					/etc/make.conf.bak) continue;;
					esac
					case $mod$type in
					+*) echo "${ppath}" >> ${add};;
					-*) echo "${ppath}" >> ${del};;
					M/) continue;;
					M*) echo "${ppath}" >> ${mod};;
					esac
				done
				sort ${add} > ${add1}
				sort ${del} > ${del1}
				sort ${mod} > ${mod1}
				comm -12 ${add1} ${del1} >> ${mod1}
				comm -23 ${add1} ${del1} > ${add}
				comm -13 ${add1} ${del1} > ${del}
				if [ -s "${add}" ]; then
					msg "Files or directories left over:"
					die=1
					cat ${add}
				fi
				if [ -s "${del}" ]; then
					msg "Files or directories removed:"
					die=1
					cat ${del}
				fi
				if [ -s "${mod}" ]; then
					msg "Files or directories modified:"
					die=1
					cat ${mod1}
				fi
				rm -f ${add} ${add1} ${del} ${del1} ${mod} ${mod1}
				[ $die -eq 0 ] || return 1
			fi
		fi
	done
	jail -r ${JAILNAME} >/dev/null
	jrun 0
	zset status "idle:"
	zfs destroy -r ${JAILFS}@preinst || :
	return 0
}

# Save wrkdir and return path to file
save_wrkdir() {
	[ $# -ne 3 ] && eargs port portdir phase
	local port="$1"
	local phase="$2"
	local portdir="$2"
	local tardir=${POUDRIERE_DATA}/wrkdirs/${JAILNAME%-job-*}/${PTNAME}
	local tarname=${tardir}/${PKGNAME}.${WRKDIR_ARCHIVE_FORMAT}
	local mnted_portdir=${JAILMNT}/wrkdirs/${portdir}

	[ -n "${SAVE_WRKDIR}" ] || return 0
	# Only save if not in fetch/checksum phase
	[ "${failed_phase}" != "fetch" -a "${failed_phase}" != "checksum" ] || return 0

	mkdir -p ${tardir}

	# Tar up the WRKDIR, and ignore errors
	case ${WRKDIR_ARCHIVE_FORMAT} in
	tar) COMPRESSKEY="" ;;
	tgz) COMPRESSKEY="z" ;;
	tbz) COMPRESSKEY="j" ;;
	txz) COMPRESSKEY="J" ;;
	esac
	rm -f ${tarname}
	tar -s ",${mnted_portdir},," -c${COMPRESSKEY}f ${tarname} ${mnted_portdir}/work > /dev/null 2>&1

	if [ -n "${MY_JOBID}" ]; then
		job_msg "Saved ${port} wrkdir to: ${tarname}"
	else
		msg "Saved ${port} wrkdir to: ${tarname}"
	fi
}

start_builders() {
	local arch=$(zget arch)
	local version=$(zget version)
	local j mnt fs name

	zfs create -o canmount=off ${JAILFS}/build

	for j in ${JOBS}; do
		mnt="${JAILMNT}/build/${j}"
		fs="${JAILFS}/build/${j}"
		name="${JAILNAME}-job-${j}"
		zset status "starting_jobs:${j}"
		mkdir -p "${mnt}"
		zfs clone -o mountpoint=${mnt} \
			-o ${NS}:name=${name} \
			-o ${NS}:type=rootfs \
			-o ${NS}:arch=${arch} \
			-o ${NS}:version=${version} \
			${JAILFS}@prepkg ${fs}
		zfs snapshot ${fs}@prepkg
		# Jail might be lingering from previous build. Already recursively
		# destroyed all the builder datasets, so just try stopping the jail
		# and ignore any errors
		jail -r ${name} >/dev/null 2>&1 || :
		MASTERMNT=${JAILMNT} JAILNAME=${name} JAILMNT=${mnt} JAILFS=${fs} do_jail_mounts 0
		MASTERMNT=${JAILMNT} JAILNAME=${name} JAILMNT=${mnt} JAILFS=${fs} do_portbuild_mounts 0
		MASTERMNT=${JAILMNT} JAILNAME=${name} JAILMNT=${mnt} JAILFS=${fs} jrun 0
		JAILFS=${fs} zset status "idle:"
	done
}

stop_builders() {
	local j mnt

	# wait for the last running processes
	cat ${JAILMNT}/poudriere/var/run/*.pid 2>/dev/null | xargs pwait 2>/dev/null

	msg "Stopping ${PARALLEL_JOBS} builders"

	for j in ${JOBS}; do
		jail -r ${JAILNAME}-job-${j} >/dev/null 2>&1 || :
	done

	mnt=`realpath ${JAILMNT}`
	mount | awk -v mnt="${mnt}/build/" 'BEGIN{ gsub(/\//, "\\\/", mnt); } { if ($3 ~ mnt && $1 !~ /\/dev\/md/ ) { print $3 }}' |  sort -r | xargs umount -f 2>/dev/null || :

	zfs destroy -r ${JAILFS}/build 2>/dev/null || :

	# No builders running, unset JOBS
	JOBS=""
}

build_stats_list() {
	[ $# -ne 3 ] && eargs html_path type display_name
	local html_path="$1"
	local type=$2
	local display_name="$3"
	local port cnt pkgname extra port_category port_name
	local status_head="" status_col=""
	local reason_head="" reason_col=""

	if [ "${type}" != "skipped" ]; then
		status_head="<th>status</th>"
	fi

	# ignored has a reason
	if [ "${type}" = "ignored" -o "${type}" = "skipped" ]; then
		reason_head="<th>reason</th>"
	elif [ "${type}" = "failed" ]; then
		reason_head="<th>phase</th>"
	fi

cat >> ${html_path} << EOF
    <div id="${type}">
      <h2>${display_name} ports </h2>
      <table>
        <tr>
          <th>Port</th>
          <th>Origin</th>
	  ${status_head}
	  ${reason_head}
        </tr>
EOF
	cnt=0
	while read port extra; do
		pkgname=$(cache_get_pkgname ${port})
		port_category=${port%/*}
		port_name=${port#*/}

		if [ -n "${status_head}" ]; then
			status_col="<td><a href=\"${pkgname}.log\">logfile</a></td>"
		fi

		if [ "${type}" = "ignored" ]; then
			reason_col="<td>${extra}</td>"
		elif [ "${type}" = "skipped" ]; then
			reason_col="<td>depends failed: <a href="#tr_pkg_${extra}">${extra}</a></td>"
		elif [ "${type}" = "failed" ]; then
			reason_col="<td>${extra}</td>"
		fi

		cat >> ${html_path} << EOF
        <tr>
          <td id="tr_pkg_${pkgname}">${pkgname}</td>
          <td><a href="http://portsmon.freebsd.org/portoverview.py?category=${port_category}&amp;portname=${port_name}">${port}</a></td>
	  ${status_col}
	  ${reason_col}
        </tr>
EOF
		cnt=$(( cnt + 1 ))
	done <  ${JAILMNT}/poudriere/ports.${type}
	zset stats_${type} $cnt

cat >> ${html_path} << EOF
      </table>
    </div>
EOF
}

build_stats() {
	local should_refresh=${1:-1}
	local port logdir pkgname html_path refresh_meta=""

	if [ "${POUDRIERE_BUILD_TYPE}" = "testport" ]; then
		# Discard test stats page for now
		html_path="/dev/null"
	else
		logdir=`log_path`
		[ -d "${logdir}" ] || mkdir -p "${logdir}"
		html_path="${logdir}/index.html.tmp"
	fi
	
	[ ${should_refresh} -eq 1 ] && \
		refresh_meta='<meta http-equiv="refresh" content="10">'

	cat > ${html_path} << EOF
<html>
  <head>
    ${refresh_meta}
    <meta http-equiv="pragma" content="NO-CACHE">
    <title>Poudriere bulk results</title>
    <style type="text/css">
      table {
        display: block;
        border: 2px;
        border-collapse:collapse;
        border: 2px solid black;
        margin-top: 5px;
      }
      th, td { border: 1px solid black; }
      #built td { background-color: #00CC00; }
      #failed td { background-color: #E00000 ; }
      #skipped td { background-color: #CC6633; }
      #ignored td { background-color: #FF9900; }
      :target { color: #FF0000; }
    </style>
    <script type="text/javascript">
      function toggle_display(id) {
        var e = document.getElementById(id);
        if (e.style.display != 'none')
          e.style.display = 'none';
        else
          e.style.display = 'block';
      }
    </script>
  </head>
  <body>
    <h1>Poudriere bulk results</h1>
    Page will auto refresh every 10 seconds.
    <ul>
      <li>Jail: ${JAILNAME}</li>
      <li>Ports tree: ${PTNAME}</li>
      <li>Set Name: ${SETNAME:-none}</li>
EOF
	cnt=$(zget stats_queued)
	cat >> ${html_path} << EOF
      <li>Nb ports queued: ${cnt}</li>
    </ul>
    <hr />
    <button onclick="toggle_display('built');">Show/Hide success</button>
    <button onclick="toggle_display('failed');">Show/Hide failure</button>
    <button onclick="toggle_display('ignored');">Show/Hide ignored</button>
    <button onclick="toggle_display('skipped');">Show/Hide skipped</button>
    <hr />
EOF

	build_stats_list "${html_path}" "built" "Successful"
	build_stats_list "${html_path}" "failed" "Failed"
	build_stats_list "${html_path}" "ignored" "Ignored"
	build_stats_list "${html_path}" "skipped" "Skipped"

	cat >> ${html_path} << EOF
  </body>
</html>
EOF


	[ "${html_path}" = "/dev/null" ] || mv ${html_path} ${html_path%.tmp}
}

build_queue() {

	local j cnt mnt fs name pkgname read_queue builders_active should_build_stats

	read_queue=1
	should_build_stats=1 # Always build stats on first pass
	while :; do
		builders_active=0
		for j in ${JOBS}; do
			mnt="${JAILMNT}/build/${j}"
			fs="${JAILFS}/build/${j}"
			name="${JAILNAME}-job-${j}"
			if [ -f  "${JAILMNT}/poudriere/var/run/${j}.pid" ]; then
				if pgrep -F "${JAILMNT}/poudriere/var/run/${j}.pid" >/dev/null 2>&1; then
					builders_active=1
					continue
				fi
				should_build_stats=1
				rm -f "${JAILMNT}/poudriere/var/run/${j}.pid"
				JAILFS="${fs}" zset status "idle:"

				# A builder finished, check the queue to see if
				# it can do some work
				read_queue=1
			fi

			# Don't want to read the queue, so just skip this
			# builder and check the next, as it may be done
			[ ${read_queue} -eq 0 ] && continue

			pkgname=$(next_in_queue)
			if [ -z "${pkgname}" ]; then
				# pool empty ?
				[ -n "$(dir_empty ${JAILMNT}/poudriere/pool)" ] && return

				# Pool is waiting on dep, wait until a build
				# is done before checking the queue again
				read_queue=0
			else
				MASTERMNT=${JAILMNT} JAILNAME="${name}" JAILMNT="${mnt}" JAILFS="${fs}" \
					MY_JOBID="${j}" \
					build_pkg "${pkgname}" >/dev/null 2>&1 &
				echo "$!" > ${JAILMNT}/poudriere/var/run/${j}.pid

				# A new job is spawned, try to read the queue
				# just to keep things moving
				read_queue=1
				builders_active=1
			fi
		done
		if [ ${read_queue} -eq 0 ]; then
			# If not wanting to read the queue, sleep to save CPU
			sleep 1
		fi

		if [ ${builders_active} -eq 0 ]; then
			msg "Dependency loop or poudriere bug detected."
			find ${JAILMNT}/poudriere/pool || echo "pool missing"
			find ${JAILMNT}/poudriere/deps || echo "deps missing"
			err 1 "Queue is unprocessable"
		fi

		if [ ${should_build_stats} -eq 1 ]; then
			build_stats
			should_build_stats=0
		fi
	done
}

# Build ports in parallel
# Returns when all are built.
parallel_build() {
	[ -z "${JAILMNT}" ] && err 2 "Fail: Missing JAILMNT"
	local nbq=$(zget stats_queued)

	# If pool is empty, just return
	test ${nbq} -eq 0 && return 0

	msg "Building ${nbq} packages using ${PARALLEL_JOBS} builders"
	JOBS="$(jot -w %02d ${PARALLEL_JOBS})"

	zset status "starting_jobs:"
	start_builders

	# Duplicate stdout to socket 5 so the child process can send
	# status information back on it since we redirect its
	# stdout to /dev/null
	exec 5<&1

	zset status "parallel_build:"
	build_queue
	build_stats 0

	zset status "stopping_jobs:"
	stop_builders
	zset status "idle:"

	# Close the builder socket
	exec 5>&-

	return $(($(zget stats_failed) + $(zget stats_skipped)))
}

clean_pool() {
	[ $# -ne 2 ] && eargs pkgname clean_rdepends
	local pkgname=$1
	local clean_rdepends=$2
	local port skipped_origin

	[ ${clean_rdepends} -eq 1 ] && port=$(cache_get_origin "${pkgname}")

	# Cleaning queue (pool is cleaned here)
	lockf -s -k ${MASTERMNT:-${JAILMNT}}/poudriere/.lock.pool sh ${SCRIPTPREFIX}/clean.sh "${MASTERMNT:-${JAILMNT}}" "${pkgname}" ${clean_rdepends} | sort -u | while read skipped_pkgname; do
		skipped_origin=$(cache_get_origin "${skipped_pkgname}")
		echo "${skipped_origin} ${pkgname}" >> ${MASTERMNT:-${JAILMNT}}/poudriere/ports.skipped
		job_msg "Skipping build of ${skipped_origin}: Dependent port ${port} failed"
	done
}

print_phase_header() {
	printf "=======================<phase: %-12s>==========================\n" "$1"
}

print_phase_footer() {
	echo "======================================================================"
}

build_pkg() {
	# If this first check fails, the pool will not be cleaned up,
	# since PKGNAME is not yet set.
	[ $# -ne 1 ] && eargs pkgname
	local pkgname="$1"
	local port portdir
	local build_failed=0
	local name cnt
	local failed_status failed_phase
	local clean_rdepends=0
	local ignore

	PKGNAME="${pkgname}" # set ASAP so cleanup() can use it
	port=$(cache_get_origin ${pkgname})
	portdir="/usr/ports/${port}"

	job_msg "Starting build of ${port}"
	zset status "starting:${port}"
	zfs rollback -r ${JAILFS}@prepkg || err 1 "Unable to rollback ${JAILFS}"

	# If this port is IGNORED, skip it
	# This is checked here instead of when building the queue
	# as the list may start big but become very small, so here
	# is a less-common check
	ignore="$(injail make -C ${portdir} -VIGNORE)"

	msg "Cleaning up wrkdir"
	rm -rf ${JAILMNT}/wrkdirs/*

	msg "Building ${port}"
	log_start $(log_path)/${PKGNAME}.log
	buildlog_start ${portdir}

	if [ -n "${ignore}" ]; then
		msg "Ignoring ${port}: ${ignore}"
		echo "${port} ${ignore}" >> "${MASTERMNT:-${JAILMNT}}/poudriere/ports.ignored"
		job_msg "Finished build of ${port}: Ignored: ${ignore}"
		clean_rdepends=1
	else
		zset status "depends:${port}"
		job_msg_verbose "Status for build ${port}: depends"
		print_phase_header "depends"
		if ! injail make -C ${portdir} pkg-depends fetch-depends extract-depends \
			patch-depends build-depends lib-depends; then
			build_failed=1
			failed_phase="depends"
		else
			print_phase_footer
			# Only build if the depends built fine
			injail make -C ${portdir} clean
			if ! build_port ${portdir}; then
				build_failed=1
				failed_status=$(zget status)
				failed_phase=${failed_status%:*}

				save_wrkdir "${port}" "${portdir}" "${failed_phase}" || :
			fi

			injail make -C ${portdir} clean
		fi

		if [ ${build_failed} -eq 0 ]; then
			echo "${port}" >> "${MASTERMNT:-${JAILMNT}}/poudriere/ports.built"

			job_msg "Finished build of ${port}: Success"
			# Cache information for next run
			pkg_cache_data "${PKGDIR}/All/${PKGNAME}.${PKG_EXT}" ${port} || :
		else
			echo "${port} ${failed_phase}" >> "${MASTERMNT:-${JAILMNT}}/poudriere/ports.failed"
			job_msg "Finished build of ${port}: Failed: ${failed_phase}"
			clean_rdepends=1
		fi
	fi

	clean_pool ${PKGNAME} ${clean_rdepends}

	zset status "done:${port}"
	buildlog_stop ${portdir}
	log_stop $(log_path)/${PKGNAME}.log
}

list_deps() {
	[ $# -ne 1 ] && eargs directory
	local dir=$1
	local makeargs="-VPKG_DEPENDS -VBUILD_DEPENDS -VEXTRACT_DEPENDS -VLIB_DEPENDS -VPATCH_DEPENDS -VFETCH_DEPENDS -VRUN_DEPENDS"
	[ -d "${PORTSDIR}/${dir}" ] && dir="/usr/ports/${dir}"

	injail make -C ${dir} $makeargs | tr '\n' ' ' | \
		sed -e "s,[[:graph:]]*/usr/ports/,,g" -e "s,:[[:graph:]]*,,g" | sort -u
}

deps_file() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1
	local depfile=$(pkg_cache_dir ${pkg})/deps

	if [ ! -f "${depfile}" ]; then
		if [ "${PKG_EXT}" = "tbz" ]; then
			injail pkg_info -qr "/usr/ports/packages/All/${pkg##*/}" | awk '{ print $2 }' > "${depfile}"
		else
			pkg info -qdF "${pkg}" > "${depfile}"
		fi
	fi

	echo ${depfile}
}

pkg_get_origin() {
	[ $# -lt 1 ] && eargs pkg
	local pkg=$1
	local originfile=$(pkg_cache_dir ${pkg})/origin
	local origin=$2

	if [ ! -f "${originfile}" ]; then
		if [ -z "${origin}" ]; then
			if [ "${PKG_EXT}" = "tbz" ]; then
				origin=$(injail pkg_info -qo "/usr/ports/packages/All/${pkg##*/}")
			else
				origin=$(pkg query -F "${pkg}" "%o")
			fi
		fi
		echo ${origin} > "${originfile}"
	else
		read origin < "${originfile}"
	fi
	echo ${origin}
}

pkg_get_options() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1
	local optionsfile=$(pkg_cache_dir ${pkg})/options
	local compiled_options

	if [ ! -f "${optionsfile}" ]; then
		if [ "${PKG_EXT}" = "tbz" ]; then
			compiled_options=$(injail pkg_info -qf "/usr/ports/packages/All/${pkg##*/}" | awk -F: '$1 == "@comment OPTIONS" {print $2}' | tr ' ' '\n' | sed -n 's/^\+\(.*\)/\1/p' | sort | tr '\n' ' ')
		else
			compiled_options=$(pkg query -F "${pkg}" '%Ov %Ok' | awk '$1 == "on" {print $2}' | sort | tr '\n' ' ')
		fi
		echo "${compiled_options}" > "${optionsfile}"
		echo "${compiled_options}"
		return
	fi
	# optionsfile is multi-line, no point for read< trick here
	cat "${optionsfile}"
}

pkg_cache_data() {
	[ $# -ne 2 ] && eargs pkg origin
	# Ignore errors in here
	set +e
	local pkg=$1
	local origin=$2
	local cachedir=$(pkg_cache_dir ${pkg})
	local originfile=${cachedir}/origin

	mkdir -p $(pkg_cache_dir ${pkg})
	pkg_get_options ${pkg} > /dev/null
	pkg_get_origin ${pkg} ${origin} > /dev/null
	deps_file ${pkg} > /dev/null
	set -e
}

pkg_to_pkgname() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1
	local pkg_file=${pkg##*/}
	local pkgname=${pkg_file%.*}
	echo ${pkgname}
}

cache_dir() {
	echo ${POUDRIERE_DATA}/cache/${JAILNAME%-job-*}/${PTNAME}${SETNAME}
}

# Return the cache dir for the given pkg
# @param string pkg $PKGDIR/All/PKGNAME.PKG_EXT
pkg_cache_dir() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1
	local pkg_file=${pkg##*/}

	echo $(cache_dir)/${pkg_file}
}

clear_pkg_cache() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1

	rm -fr $(pkg_cache_dir ${pkg})
}

delete_pkg() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1

	# Delete the package and the depsfile since this package is being deleted,
	# which will force it to be recreated
	rm -f "${pkg}"
	clear_pkg_cache ${pkg}
}

# Deleted cached information for stale packages (manually removed)
delete_stale_pkg_cache() {
	local pkgname
	local cachedir=$(cache_dir)
	[ ! -d ${cachedir} ] && return 0
	[ -n "$(dir_empty ${cachedir})" ] && return 0
	for pkg in ${cachedir}/*.${PKG_EXT}; do
		pkg_file=${pkg##*/}
		# If this package no longer exists in the PKGDIR, delete the cache.
		if [ ! -e "${PKGDIR}/All/${pkg_file}" ]; then
			clear_pkg_cache ${pkg}
		fi
	done
}

delete_old_pkg() {
	local pkg="$1"
	local o v v2 compiled_options current_options
	if [ "${pkg##*/}" = "repo.txz" ]; then
		msg "Removing invalid pkg repo file: ${pkg}"
		rm -f ${pkg}
		return 0
	fi

	mkdir -p $(pkg_cache_dir ${pkg})

	o=$(pkg_get_origin ${pkg})
	v=${pkg##*-}
	v=${v%.*}
	if [ ! -d "${JAILMNT}/usr/ports/${o}" ]; then
		msg "${o} does not exist anymore. Deleting stale ${pkg##*/}"
		delete_pkg ${pkg}
		return 0
	fi
	v2=$(cache_get_pkgname ${o})
	v2=${v2##*-}
	if [ "$v" != "$v2" ]; then
		msg "Deleting old version: ${pkg##*/}"
		delete_pkg ${pkg}
		return 0
	fi

	# Check if the compiled options match the current options from make.conf and /var/db/options
	if [ "${CHECK_CHANGED_OPTIONS:-no}" != "no" ]; then
		current_options=$(injail make -C /usr/ports/${o} pretty-print-config | tr ' ' '\n' | sed -n 's/^\+\(.*\)/\1/p' | sort | tr '\n' ' ')
		compiled_options=$(pkg_get_options ${pkg})

		if [ "${compiled_options}" != "${current_options}" ]; then
			msg "Options changed, deleting: ${pkg##*/}"
			if [ "${CHECK_CHANGED_OPTIONS}" = "verbose" ]; then
				msg "Pkg: ${compiled_options}"
				msg "New: ${current_options}"
			fi
			delete_pkg ${pkg}
			return 0
		fi
	fi
}

delete_old_pkgs() {
	[ ! -d ${PKGDIR}/All ] && return 0
	[ -n "$(dir_empty ${PKGDIR}/All)" ] && return 0
	for pkg in ${PKGDIR}/All/*.${PKG_EXT}; do
		# Check for non-empty directory with no packages in it
		[ "${pkg}" = "${PKGDIR}/All/*.${PKG_EXT}" ] && break
		parallel_run "delete_old_pkg ${pkg}"
	done
	parallel_stop
}

next_in_queue() {
	local p
	[ ! -d ${JAILMNT}/poudriere/pool ] && err 1 "Build pool is missing"
	p=$(lockf -k -t 60 ${JAILMNT}/poudriere/.lock.pool find ${JAILMNT}/poudriere/pool -type d -depth 1 -empty -print -quit || :)
	[ -n "$p" ] || return 0
	touch ${p}/.building
	# pkgname
	echo ${p##*/}
}

lock_acquire() {
	[ $# -ne 1 ] && eargs lockname
	local lockname=$1

	while :; do
		if mkdir ${POUDRIERE_DATA}/.lock-${JAILNAME}-${lockname} 2>/dev/null; then
			break
		fi
		sleep 0.1
	done
}

lock_release() {
	[ $# -ne 1 ] && eargs lockname
	local lockname=$1

	rmdir ${POUDRIERE_DATA}/.lock-${JAILNAME}-${lockname} 2>/dev/null
}

cache_get_pkgname() {
	[ $# -ne 1 ] && eargs origin
	local origin=$1
	local pkgname="" existing_origin
	local cache_origin_pkgname=${MASTERMNT:-${JAILMNT}}/poudriere/var/cache/origin-pkgname/${origin%%/*}_${origin##*/}
	local cache_pkgname_origin

	[ -f ${cache_origin_pkgname} ] && read pkgname < ${cache_origin_pkgname}

	# Add to cache if not found.
	if [ -z "${pkgname}" ]; then
		pkgname=$(injail make -C /usr/ports/${origin} -VPKGNAME)
		# Make sure this origin did not already exist
		existing_origin=$(cache_get_origin "${pkgname}" 2>/dev/null || :)
		# It may already exist due to race conditions, it is not harmful. Just ignore.
		if [ "${existing_origin}" != "${origin}" ]; then
			[ -n "${existing_origin}" ] && \
				err 1 "Duplicated origin for ${pkgname}: ${origin} AND ${existing_origin}. Rerun with -vv to see which ports are depending on these."
			echo "${pkgname}" > ${cache_origin_pkgname}
			cache_pkgname_origin="${MASTERMNT:-${JAILMNT}}/poudriere/var/cache/pkgname-origin/${pkgname}"
			echo "${origin}" > "${cache_pkgname_origin}"
		fi
	fi

	echo ${pkgname}
}

cache_get_origin() {
	[ $# -ne 1 ] && eargs pkgname
	local pkgname=$1
	local cache_pkgname_origin="${MASTERMNT:-${JAILMNT}}/poudriere/var/cache/pkgname-origin/${pkgname}"

	cat "${cache_pkgname_origin}"
}

# Take optional pkgname to speedup lookup
compute_deps() {
	[ $# -lt 1 ] && eargs port
	[ $# -gt 2 ] && eargs port pkgnme
	local port=$1
	local pkgname="${2:-$(cache_get_pkgname ${port})}"
	local dep_pkgname dep_port
	local pkg_pooldir="${JAILMNT}/poudriere/deps/${pkgname}"
	mkdir "${pkg_pooldir}" 2>/dev/null || return 0

	msg_verbose "Computing deps for ${port}"

	for dep_port in `list_deps ${port}`; do
		msg_debug "${port} depends on ${dep_port}"
		dep_pkgname=$(cache_get_pkgname ${dep_port})

		# Only do this if it's not already done, and not ALL, as everything will
		# be touched anyway
		[ ${ALL:-0} -eq 0 ] && ! [ -d "${JAILMNT}/poudriere/deps/${dep_pkgname}" ] && \
			compute_deps "${dep_port}" "${dep_pkgname}"

		touch "${pkg_pooldir}/${dep_pkgname}"
		mkdir -p "${JAILMNT}/poudriere/rdeps/${dep_pkgname}"
		ln -sf "${pkg_pooldir}/${dep_pkgname}" \
			"${JAILMNT}/poudriere/rdeps/${dep_pkgname}/${pkgname}"
	done
}

listed_ports() {
	if [ ${ALL:-0} -eq 1 ]; then
		PORTSDIR=`porttree_get_base ${PTNAME}`
		[ -d "${PORTSDIR}/ports" ] && PORTSDIR="${PORTSDIR}/ports"
		for cat in $(awk '$1 == "SUBDIR" { print $3}' ${PORTSDIR}/Makefile); do
			awk -v cat=${cat}  '$1 == "SUBDIR" { print cat"/"$3}' ${PORTSDIR}/${cat}/Makefile
		done
		return
	fi
	if [ -z "${LISTPORTS}" ]; then
		if [ -n "${LISTPKGS}" ]; then
			grep -v -E '(^[[:space:]]*#|^[[:space:]]*$)' ${LISTPKGS}
		fi
	else
		echo ${LISTPORTS} | tr ' ' '\n'
	fi
}

parallel_stop() {
	wait
}

_reap_children() {
	local skip_count=${1:-0}
	_child_count=0
	running_jobs=$(jobs -p) # |wc -l here will always be 0
	for pid in ${running_jobs}; do
		_child_count=$((_child_count + 1))
	done
	[ ${_child_count} -lt ${skip_count} ] && return 0

	# No available slot, try to reap some children to find one
	for pid in ${running_jobs}; do
		if ! kill -0 ${pid} 2>/dev/null; then
			wait ${pid} 2>/dev/null || :
			_child_count=$((_child_count - 1))
		fi
	done
}

parallel_run() {
	local cmd="$@"

	while :; do
		_reap_children ${_REAL_PARALLEL_JOBS}
		if [ ${_child_count} -lt ${_REAL_PARALLEL_JOBS} ]; then
			# Execute the command in the background
			eval "${cmd} &"
			return 0
		fi
		sleep 0.1
	done

	return 0
}

# Get all data that make this build env unique,
# so if the same build is done again,
# we can use the some of the same cached data
cache_get_key() {
	if [ -z "${CACHE_KEY}" ]; then
		CACHE_KEY=$({
			injail env
			injail cat /etc/make.conf
			injail find /var/db/ports -exec sha256 {} +
			echo ${JAILNAME}-${SETNAME}-${PTNAME}
			if [ -f ${JAILMNT}/usr/ports/.poudriere.stamp ]; then
				cat ${JAILMNT}/usr/ports/.poudriere.stamp
			else
				# This is not a poudriere-managed ports tree.
				# Just toss in getpid() to invalidate the cache
				# as there is no quick way to hash the tree without
				# taking possibly minutes+
				echo $$
			fi
		} | sha256)
	fi
	echo ${CACHE_KEY}
}

prepare_ports() {
	local pkg

	_REAL_PARALLEL_JOBS=${PARALLEL_JOBS}

	msg "Calculating ports order and dependencies"
	mkdir -p "${JAILMNT}/poudriere"
	[ -n "${TMPFS_DATA}" ] && mount -t tmpfs tmpfs "${JAILMNT}/poudriere"
	rm -rf "${JAILMNT}/poudriere/var/cache/origin-pkgname" \
	       "${JAILMNT}/poudriere/var/cache/pkgname-origin" 2>/dev/null || :
	mkdir -p "${JAILMNT}/poudriere/pool" \
		"${JAILMNT}/poudriere/deps" \
		"${JAILMNT}/poudriere/rdeps" \
		"${JAILMNT}/poudriere/var/run" \
		"${JAILMNT}/poudriere/var/cache" \
		"${JAILMNT}/poudriere/var/cache/origin-pkgname" \
		"${JAILMNT}/poudriere/var/cache/pkgname-origin"

	zset stats_queued "0"
	:> ${JAILMNT}/poudriere/ports.built
	:> ${JAILMNT}/poudriere/ports.failed
	:> ${JAILMNT}/poudriere/ports.ignored
	:> ${JAILMNT}/poudriere/ports.skipped
	build_stats

	zset status "computingdeps:"
	for port in $(listed_ports); do
		[ -d "${PORTSDIR}/${port}" ] || err 1 "Invalid port origin: ${port}"
		parallel_run "compute_deps ${port}"
	done
	parallel_stop


	zset status "sanity:"

	if [ ${CLEAN_LISTED:-0} -eq 1 ]; then
		listed_ports | while read port; do
			pkg="${PKGDIR}/All/$(cache_get_pkgname  ${port}).${PKG_EXT}"
			if [ -f "${pkg}" ]; then
				msg "Deleting existing package: ${pkg##*/}"
				delete_pkg ${pkg}
			fi
		done
	fi

	if [ $SKIPSANITY -eq 0 ]; then
		msg "Sanity checking the repository"
		delete_stale_pkg_cache
		delete_old_pkgs

		while :; do
			sanity_check_pkgs && break
		done
	fi

	msg "Deleting stale symlinks"
	find -L ${PKGDIR} -type l -exec rm -vf {} +

	zset status "cleaning:"
	msg "Cleaning the build queue"
	export LOCALBASE=${MYBASE:-/usr/local}
	for pn in $(ls ${JAILMNT}/poudriere/deps/); do
		if [ -f "${PKGDIR}/All/${pn}.${PKG_EXT}" ]; then
			# Cleanup rdeps/*/${pn}
			for rpn in $(ls "${JAILMNT}/poudriere/deps/${pn}"); do
				echo "${JAILMNT}/poudriere/rdeps/${rpn}/${pn}"
			done
			echo "${JAILMNT}/poudriere/deps/${pn}"
			# Cleanup deps/*/${pn}
			if [ -d "${JAILMNT}/poudriere/rdeps/${pn}" ]; then
				for rpn in $(ls "${JAILMNT}/poudriere/rdeps/${pn}"); do
					echo "${JAILMNT}/poudriere/deps/${rpn}/${pn}"
				done
				echo "${JAILMNT}/poudriere/rdeps/${pn}"
			fi
		fi
	done | xargs rm -rf

	local nbq=0
	nbq=$(find ${JAILMNT}/poudriere/deps -type d -depth 1 | wc -l)
	zset stats_queued "${nbq##* }"

	# Create a pool of ready-to-build from the deps pool
	find "${JAILMNT}/poudriere/deps" -type d -empty|xargs -J % mv % "${JAILMNT}/poudriere/pool"

	# Minimize PARALLEL_JOBS to queue size
	if [ ${PARALLEL_JOBS} -gt ${nbq} ]; then
		PARALLEL_JOBS=${nbq##* }
	fi
}

append_make() {
	[ $# -ne 1 ] && eargs makeconf
	local makeconf="$(realpath "$1")"

	msg "Appending to /etc/make.conf: ${makeconf}"
	cat "${makeconf}" >> ${JAILMNT}/etc/make.conf
}

prepare_jail() {
	if [ -z "${NO_PACKAGE_BUILDING}" ]; then
		export PACKAGE_BUILDING=yes
	fi
	export FORCE_PACKAGE=yes
	export USER=root
	export HOME=/root
	PORTSDIR=`porttree_get_base ${PTNAME}`
	[ -d "${PORTSDIR}/ports" ] && PORTSDIR="${PORTSDIR}/ports"
	[ -z "${JAILMNT}" ] && err 1 "No path of the base of the jail defined"
	[ -z "${PORTSDIR}" ] && err 1 "No ports directory defined"
	[ -z "${PKGDIR}" ] && err 1 "No package directory defined"
	[ -n "${MFSSIZE}" -a -n "${USE_TMPFS}" ] && err 1 "You can't use both tmpfs and mdmfs"

	msg "Mounting ports from: ${PORTSDIR}"
	do_portbuild_mounts 1

	[ ! -d ${DISTFILES_CACHE} ] && err 1 "DISTFILES_CACHE directory	does not exists. (c.f. poudriere.conf)"

	[ -f ${POUDRIERED}/make.conf ] && append_make ${POUDRIERED}/make.conf
	[ -f ${POUDRIERED}/${SETNAME#-}-make.conf ] && append_make ${POUDRIERED}/${SETNAME#-}-make.conf
	[ -f ${POUDRIERED}/${PTNAME}-make.conf ] && append_make ${POUDRIERED}/${PTNAME}-make.conf
	[ -f ${POUDRIERED}/${JAILNAME}-make.conf ] && append_make ${POUDRIERED}/${JAILNAME}-make.conf
	[ -f ${POUDRIERED}/${JAILNAME}-${PTNAME}-make.conf ] && append_make ${POUDRIERED}/${JAILNAME}-${PTNAME}-make.conf
	[ -n "${SETNAME}" -a -f ${POUDRIERED}/${JAILNAME}${SETNAME}-make.conf ] && append_make ${POUDRIERED}/${JAILNAME}${SETNAME}-make.conf
	if [ -z "${NO_PACKAGE_BUILDING}" ]; then
		echo "PACKAGE_BUILDING=yes" >> ${JAILMNT}/etc/make.conf
	fi

	msg "Populating LOCALBASE"
	mkdir -p ${JAILMNT}/${MYBASE:-/usr/local}
	injail /usr/sbin/mtree -q -U -f /usr/ports/Templates/BSD.local.dist -d -e -p ${MYBASE:-/usr/local} >/dev/null

	WITH_PKGNG=$(injail make -f /usr/ports/Mk/bsd.port.mk -V WITH_PKGNG)
	if [ -n "${WITH_PKGNG}" ]; then
		export PKGNG=1
		export PKG_EXT="txz"
		export PKG_ADD="${MYBASE:-/usr/local}/sbin/pkg add"
		export PKG_DELETE="${MYBASE:-/usr/local}/sbin/pkg delete -y -f"
	else
		export PKGNG=0
		export PKG_ADD=pkg_add
		export PKG_DELETE=pkg_delete
		export PKG_EXT="tbz"
	fi

	export LOGS=${POUDRIERE_DATA}/logs
}

RESOLV_CONF=""
STATUS=0 # out of jail #

test -f ${SCRIPTPREFIX}/../../etc/poudriere.conf || err 1 "Unable to find ${SCRIPTPREFIX}/../../etc/poudriere.conf"
. ${SCRIPTPREFIX}/../../etc/poudriere.conf
POUDRIERED=${SCRIPTPREFIX}/../../etc/poudriere.d

[ -z ${ZPOOL} ] && err 1 "ZPOOL variable is not set"
[ -z ${BASEFS} ] && err 1 "Please provide a BASEFS variable in your poudriere.conf"

trap sig_handler SIGINT SIGTERM SIGKILL
trap exit_handler EXIT
trap siginfo_handler SIGINFO

# Test if spool exists
zpool list ${ZPOOL} >/dev/null 2>&1 || err 1 "No such zpool: ${ZPOOL}"
ZVERSION=$(zpool list -H -oversion ${ZPOOL})
# Pool version has now
if [ "${ZVERSION}" = "-" ]; then
	ZVERSION=29
fi

: ${SVN_HOST="svn.FreeBSD.org"}
: ${GIT_URL="git://github.com/freebsd/freebsd-ports.git"}
: ${FREEBSD_HOST="ftp://${FTP_HOST:-ftp.FreeBSD.org}"}
: ${ZROOTFS="/poudriere"}

case ${ZROOTFS} in
	[!/]*)
		err 1 "ZROOTFS shoud start with a /"
		;;
esac

: ${CRONDIR="${POUDRIERE_DATA}/cron"}
POUDRIERE_DATA=`get_data_dir`
: ${WRKDIR_ARCHIVE_FORMAT="tbz"}
case "${WRKDIR_ARCHIVE_FORMAT}" in
	tar|tgz|tbz|txz);;
	*) err 1 "invalid format for WRKDIR_ARCHIVE_FORMAT: ${WRKDIR_ARCHIVE_FORMAT}" ;;
esac

case ${PARALLEL_JOBS} in
''|*[!0-9]*)
	PARALLEL_JOBS=$(sysctl -n hw.ncpu)
	;;
esac
