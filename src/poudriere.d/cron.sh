#!/bin/sh
set -e

SCRIPTPATH=`realpath $0`
SCRIPTPREFIX=`dirname ${SCRIPTPATH}`
. ${SCRIPTPREFIX}/common.sh

[ -z ${CRONDIR} ] && err 1 "Please provide a CRONDIR variable in your poudriere.conf"
[ `stat -f '%Sp' ${CRONDIR}` != "drwxrwxrwt" ] && err 1 "Please fix permissions on ${CRONDIR} (see poudriere.conf)"

if [ -d ${CRONDIR} ]; then
	CMDFILE=`ls -t ${CRONDIR}/poudriere-* 2>/dev/null | tail -1`
	if [ -z "${CMDFILE}" ]; then
		COMMAND=`cat ${CMDFILE}`
		poudriere ${COMMAND} && rm ${CMDFILE}
	fi
fi