#!/bin/sh

usage() {
	echo "pourdriere createJail -n name -v version [-a architecture] [-z zfs] -m [FTP|NONE] "
	echo "by default architecture is the same as the host (amd64 can create i386 jails)"
	echo "by default a new zfs filesystem will be created in the dedicated pool"
	echo "by default the next IP available in the pourdriere pool will be used"
	echo "by default the FTP method is used but you can add you home made jail with NONE -v and -a will be ignored in that case"
	exit 1
}

err() {
	if [ $# -ne 2 ]; then
		err 1 "err expects 2 arguments: exit_number \"message\""
	fi
	echo "$2"
	exit $1
}

create_base_fs() {
	echo -n "===> Creating basefs:"
	zfs create -o mountpoint=${BASEFS:=/usr/local/poudriere} $ZPOOL/poudriere >/dev/null 2>&1 || err 1 " Fail" && echo " done"
}

ARCH=`uname -m`
METHOD="FTP"

test -f /usr/local/etc/poudriere.conf || err 1 "Unable to find /usr/local/etc/poudriere.conf"

. /usr/local/etc/poudriere.conf

test -z $ZPOOL && err 1 "ZPOOL variable is not set"

# Test if spool exists
zpool list $ZPOOL >/dev/null 2>&1 || err 1 "No such zpool : $ZPOOL"

#Test if the default FS for pourdriere exists if not creates it
zfs list $ZPOOL/poudriere >/dev/null 2>&1 || create_base_fs

while getopts "n:v:a:z:i:m:" FLAG; do
	case "$FLAG" in
		n)
		NAME=$OPTARG
		;;
		v)
		VERSION=$OPTARG
		;;
		a)
		ARCH=$OPTARG
		;;
		z)
		FS=$
		;;
		;;
		m)
		METHOD=$OPTARG
		;;
		*)
			usage
		;;
	esac
done

test -z $NAME && usage

if [ "$METHOD" = "FTP" ]; then
	test -z $VERSION && usage
fi

# Test if a jail with this name already exists
zfs list -r $ZPOOL/poudriere/$NAME >/dev/null 2>&1 && err 2 "The jail $NAME already exists"

# Create the jail FS
echo -n "====> Creating $NAME fs:"
zfs create -o mountpoint=${BASEFS:=/usr/local/poudriere}/$NAME $ZPOOL/poudriere/$NAME >/dev/null 2>&1 || err 1 " Fail" && echo " done"

#We need to fetch base and src (for drivers)
echo "====> Fetching base sets for FreeBSD $VERSION $ARCH"
PKGS=`echo "ls base*"| ftp -aV ftp://${FTPHOST:=ftp.freebsd.org}/pub/FreeBSD/releases/$ARCH/$VERSION/base/ | awk '{print $NF}'`
mkdir $BASEFS/$NAME/fromftp
for pkg in $PKGS; do
# Let's retry at least one time
	fetch -o $BASEFS/$NAME/fromftp/$pkg ftp://${FTPHOST}/pub/FreeBSD/releases/$ARCH/$VERSION/base/$pkg || fetch -o $BASEFS/$NAME/fromftp/$pkg ftp://${FTPHOST}/pub/FreeBSD/releases/$ARCH/$VERSION/base/$pkg
done
echo -n "====> Extracting base:"
cat $BASEFS/$NAME/fromftp/base.* | tar --unlink -xpzf - -C $BASEFS/$NAME/ || err 1 " Fail" && echo " done"
echo -n "====> Cleaning Up base sets:"
rm $BASEFS/$NAME/fromftp/*
echo " done"

echo "====> Fetching ssys sets"
PKGS=`echo "ls ssys*"| ftp -aV ftp://${FTPHOST:=ftp.freebsd.org}/pub/FreeBSD/releases/$ARCH/$VERSION/src/ | awk '{print $NF}'`
mkdir $BASEFS/$NAME/fromftp
for pkg in $PKGS; do
# Let's retry at least one time
	fetch -o $BASEFS/$NAME/fromftp/$pkg ftp://${FTPHOST}/pub/FreeBSD/releases/$ARCH/$VERSION/src/$pkg || fetch -o $BASEFS/$NAME/fromftp/$pkg ftp://${FTPHOST}/pub/FreeBSD/releases/$ARCH/$VERSION/src/$pkg
done
echo -n "====> Extracting ssyss:"
cat $BASEFS/$NAME/fromftp/ssys.* | tar --unlink -xpzf - -C $BASEFS/$NAME/ || err 1 " Fail" && echo " done"
echo -n "====> Cleaning Up srcs sets:"
rm $BASEFS/$NAME/fromftp/*
echo " done"

if [ "$ARCH" = "i386" -a `uname -m` = "amd64" ];then
#TODO
fi

cat > $BASEFS/$NAME/poudriere-jail.conf << EOF
Version: $VERSION
Arch: $ARCH
EOF
zfs snapshot $ZPOOL/poudriere/$NAME@clean
echo "====> Jail $NAME $VERSION $ARCH is ready to be used"
