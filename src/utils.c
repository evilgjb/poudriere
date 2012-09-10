#include <sys/types.h>
#include <sys/sbuf.h>
#include <sys/param.h>
#include <sys/jail.h>
#include <sys/ucred.h>
#include <sys/mount.h>
#include <sys/linker.h>
#include <sys/uio.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/sysctl.h>

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <jail.h>
#include <err.h>
#include <errno.h>
#include <login_cap.h>
#include <pwd.h>

#include "utils.h"
#include "poudriere.h"

static struct sbuf *
exec_buf(const char *cmd)
{
	FILE *fp;
	char buf[BUFSIZ];
	struct sbuf *res;

	if ((fp = popen(cmd, "r")) == NULL)
		return (NULL);

	res = sbuf_new_auto();
	while (fgets(buf, BUFSIZ, fp) != NULL)
		sbuf_cat(res, buf);

	pclose(fp);

	if (sbuf_len(res) == 0) {
		sbuf_delete(res);
		return (NULL);
	}

	sbuf_finish(res);

	return (res);
}

int
split_chr(char *str, char sep)
{
	char *next;
	char *buf = str;
	int nbel = 0;

	while ((next = strchr(buf, sep)) != NULL) {
		nbel++;
		buf = next;
		buf[0] = '\0';
		buf++;
	}

	return nbel;
}

struct sbuf *
injail_buf(struct pjail *j, char *cmd)
{
	FILE *fp;
	char buf[BUFSIZ];
	struct sbuf *res;
	struct sbuf *command;

	command = sbuf_new_auto();
	sbuf_printf(command, "jexec -U root %s %s", j->name, cmd);
	sbuf_finish(command);
	if ((fp = popen(sbuf_data(command), "r")) == NULL)
		return (NULL);

	res = sbuf_new_auto();
	while (fgets(buf, BUFSIZ, fp) != NULL)
		sbuf_cat(res, buf);

	pclose(fp);

	sbuf_delete(command);
	if (sbuf_len(res) == 0) {
		sbuf_delete(res);
		return (NULL);
	}

	sbuf_finish(res);

	return (res);
}

int
exec(char *path, char *const argv[])
{
	int pstat;
	pid_t pid;

	switch ((pid = fork())) {
	case -1:
		return (-1);
	case 0:
		execv(path, argv);
		_exit(1);
		/* NOTREACHED */
	default:
		/* parent */
		break;
	}

	while (waitpid(pid, &pstat, 0) == -1) {
		if (errno != EINTR)
			return (-1);
	}

	return (WEXITSTATUS(pstat));
};

int
jexec(struct pjail *j, char *argv[])
{
	int jid;
	int pstat;
	pid_t pid;
	struct passwd *pwd;
	login_cap_t *lcap;

	jid = jail_getid(j->name);
	if (jid == -1)
		return (jid);

	switch((pid = fork())) {
	case -1:
		break;
	case 0:
		jail_attach(jid);
		chdir("/");
		pwd = getpwnam("root");
		lcap = login_getpwclass(pwd);
		initgroups(pwd->pw_name, pwd->pw_gid);
		setgid(pwd->pw_gid);
		setusercontext(lcap, pwd, pwd->pw_uid,
		    LOGIN_SETALL & ~LOGIN_SETGROUP & ~LOGIN_SETLOGIN);
		login_close(lcap);
		execvp(argv[1], argv + 1);
		exit(0);
		break;
	default:
		break;
	}

	while (waitpid(pid, &pstat, 0) == -1) {
		if (errno != EINTR)
			return (-1);
	}

	return (WEXITSTATUS(pstat));
}

void
zfs_list(struct zfs_prop z[], const char *t, int n)
{
	struct sbuf *res, *cmd;
	char *walk, *end;
	const char *type;
	char **fields;
	int i=0;
	int j=0;

	cmd = sbuf_new_auto();
	fields = malloc(n * sizeof(char *));

	sbuf_cat(cmd, "/sbin/zfs list -r -H -o poudriere:type");
	for (i = 0; i < n; i++)
		sbuf_printf(cmd, ",poudriere:%s", z[i].name);
	sbuf_finish(cmd);
	for (i = 0; i < n; i++)
		printf(z[i].format, z[i].title);

	if ((res = exec_buf(sbuf_data(cmd))) != NULL) {
		walk = sbuf_data(res);
		end = walk + sbuf_len(res);
		type = walk;
		for (i = 0; i < n; i++)
			fields[i] = NULL;
		while (!isspace(*walk))
			walk++;
		while (walk <= end) {
			while (isspace(*walk)) {
				*walk = '\0';
				walk++;
			}
			fields[j++] = walk;

			while (!isspace(*walk))
				walk++;
			*walk = '\0';
			walk++;
			
			if (j < n)
				continue;

			if (strcmp(type, t) == 0) {
				for (i = 0; i < n; i++)
					printf(z[i].format, fields[i]);
			}
			while (isspace(*walk)) {
				*walk = '\0';
				walk++;
			}
			type = walk;
			j = 0;
			while (!isspace(*walk))
				walk++;
			*walk = '\0';
			walk++;
		}
		sbuf_delete(res);
	}
	free(fields);
	sbuf_delete(cmd);
}

int
zfs_query(const char *t, const char *n, struct zfs_query z[], int nfields)
{
	struct sbuf *res, *cmd;
	char *walk, *end;
	const char *type, *name;
	char **fields;
	int i = 0;
	int ret = 0;
	int j = 0;

	cmd = sbuf_new_auto();
	fields = malloc(nfields * sizeof(char *));

	sbuf_cat(cmd, "/sbin/zfs list -r -H -o poudriere:type,poudriere:name");
	for (i = 0; i < nfields; i++)
		sbuf_printf(cmd, ",%s", z[i].name);
	sbuf_finish(cmd);

	if ((res = exec_buf(sbuf_data(cmd))) != NULL) {
		walk = sbuf_data(res);
		end = walk + sbuf_len(res);
		type = walk;
		name = NULL;
		for (i = 0; i < nfields; i++)
			fields[i] = NULL;
		while (!isspace(*walk))
			walk++;
		while (walk <= end) {
			while (isspace(*walk)) {
				*walk = '\0';
				walk++;
			}
			if (name == NULL)
				name = walk;
			else
				fields[j++] = walk;

			while (!isspace(*walk))
				walk++;
			*walk = '\0';
			walk++;

			if (j < nfields)
				continue;

			if (strcmp(type, t) == 0 && strcmp(name, n) == 0) {
				for (i = 0; i < nfields; i++) {
					switch (z[i].type) {
					case STRING:
						strlcpy(z[i].strval, fields[i], z[i].strsize);
						break;
					case INTEGER:
						if (strcmp(fields[i], "-") == 0)
							z[i].intval = 0;
						else 
							z[i].intval = strtonum(fields[i], 0, INT_MAX, NULL);
						break;
					}
				}
				ret = 1;
				break;
			}
			type = walk;
			name = NULL;
			j = 0;
			while (!isspace(*walk))
				walk++;
			*walk= '\0';
			walk++;
		}
		sbuf_delete(res);
	}
	free(fields);
	sbuf_delete(cmd);

	return (ret);
}

int
jail_runs(const char *jailname)
{
	int jid;

	if ((jid = jail_getid(jailname)) < 0)
		return 0;

	return 1;
}

static const char *needfs[] = {
	"linprocfs",
	"linsysfs",
	"procfs",
	"nullfs",
	"xfs",
	NULL,
};
static struct mntpts {
	const char *dest;
	char *fstype;
} mntpts [] = {
	{ "/dev", "devfs" },
	{ "/compat/linux/proc", "linprocfs" },
	{ "/compat/linux/sys", "linsysfs" },
	{ "/proc", "procfs" },
	{ NULL, NULL },
};

static int
mkdirs(const char *_path)
{
	char path[MAXPATHLEN + 1];
	char *p;

	strlcpy(path, _path, sizeof(path));
	p = path;
	if (*p == '/')
		p++;

	for (;;) {
		if ((p = strchr(p, '/')) != NULL)
			*p = '\0';

		if (mkdir(path, S_IRWXU | S_IRWXG | S_IRWXO) < 0)
			if (errno != EEXIST && errno != EISDIR) {
				return (0);
			}

		/* that was the last element of the path */
		if (p == NULL)
			break;

		*p = '/';
		p++;
	}

	return (1);
}

void
jail_run(struct pjail *j, bool network)
{
	int jid;

	jid = jail_getid(j->name);
	if (jid != -1)
		jail_remove(jid);

	printf("Starting %s\n", j->name);
	jid = jail_setv(JAIL_CREATE,
	    "name", j->name,
	    "host.hostname", j->name,
	    "path", j->mountpoint,
	    "persist", "true",
	    "allow.sysvipc", "true",
	    "allow.mount", "true",
	    "allow.socket_af", "true",
	    "allow.raw_sockets", "true",
	    "allow.chflags", "true",
	    network ? "ip4" : "ip4.addr", network ? "inherit" : "127.0.0.1",
	    network ? "ip6" : "ip6.addr", network ? "inherit" : "::1",
	    NULL);

	if (jid == -1)
		warn("Fail to start jail: %s" , jail_errmsg);
}

void
jail_kill(struct pjail *j)
{
	int jid;

	jid = jail_getid(j->name);
	if (jid == -1)
		return;

	if (jail_remove(jid) < 0)
		warn("Fail to stop jail");

	return;
}

void
jail_start(struct pjail *j, bool network)
{
	int i;
	struct xvfsconf vfc;
	int iovlen;
	struct iovec iov[6];
	char dest[MAXPATHLEN];
	size_t sysvallen;

	if (jail_runs(j->name)) {
		fprintf(stderr, "====>> jail %s is already running\n", j->name);
		return;
	}
	
	for (i = 0; needfs[i] != NULL; i++) {
		if (getvfsbyname(needfs[i], &vfc) < 0)
			if (kldload(needfs[i]) == -1) {
				fprintf(stderr, "failed to load %s\n", needfs[i]);
				return;
			}
	}
	if (conf.use_tmpfs) {
		if (getvfsbyname(needfs[i], &vfc) < 0)
			if (kldload(needfs[i]) == -1) {
				fprintf(stderr, "failed to load %s\n", needfs[i]);
				return;
			}
	}

	for (i = 0; mntpts[i].dest != NULL; i++) {
		snprintf(dest, MAXPATHLEN, "%s/%s", j->mountpoint, mntpts[i].dest);
		if (!mkdirs(dest)) {
			warn("failed to create dirs: %s", dest);
			continue;
		}
		iov[0].iov_base = "fstype";
		iov[0].iov_len = sizeof("fstype");
		iov[1].iov_base = mntpts[i].fstype;
		iov[1].iov_len = strlen(mntpts[i].fstype) + 1;
		iov[2].iov_base = "fspath";
		iov[2].iov_len = sizeof("fspath");
		iov[3].iov_base = dest;
		iov[3].iov_len = strlen(dest) + 1;
		if (nmount(iov, 4, 0))
			warn("failed to mount %s", dest);
	}

	jail_run(j, false);

	return;
}

void
mount_nullfs(struct pjail *j, struct pport_tree *p)
{
	struct iovec iov[6];
	char source[MAXPATHLEN], target[MAXPATHLEN];

	iov[0].iov_base = "fstype";
	iov[0].iov_len = sizeof("fstype");
	iov[1].iov_base = "nullfs";
	iov[1].iov_len = strlen(iov[1].iov_base) + 1;
	iov[2].iov_base = "fspath";
	iov[2].iov_len = sizeof("fspath");

	/* ports */
	snprintf(target, sizeof(target), "%s/ports", p->mountpoint);
	snprintf(source, sizeof(source), "%s/usr/ports", j->mountpoint);

	if (mkdir(target, 0755) != 0 && errno != EEXIST)
		err(1, "Unable to create dir: %s", target);

	if (mkdir(source, 0755) != 0 && errno != EEXIST)
		err(1, "Unable to create dir: %s", source);

	iov[3].iov_base = source;
	iov[3].iov_len =  strlen(source) + 1;

	iov[4].iov_base = "target";
	iov[4].iov_len = sizeof("target");

	iov[5].iov_base = target;
	iov[5].iov_len = strlen(target) + 1;

	if (nmount(iov, 6, 0))
		err(1, "failed to mount %s on %s\n", source, target);

	/* packages */
	snprintf(target, sizeof(target), "%s/packages", conf.poudriere_data);
	if (mkdir(target, 0755) != 0 && errno != EEXIST)
		err(1, "Unable to create dir: %s", target);
	snprintf(target, sizeof(target), "%s/packages/%s-%s",
	    conf.poudriere_data, j->name, p->name);
	if (mkdir(target, 0755) != 0 && errno != EEXIST)
		err(1, "Unable to create dir: %s", target);
	snprintf(source, sizeof(source), "%s/usr/ports/packages", j->mountpoint);

	if (mkdir(source, 0755) != 0 && errno != EEXIST)
		err(1, "Unable to create dir: %s", source);

	iov[3].iov_base = source;
	iov[3].iov_len =  strlen(source) + 1;

	iov[5].iov_base = target;
	iov[5].iov_len = strlen(target) + 1;

	if (nmount(iov, 6, 0))
		err(1, "failed to mount %s\n", target);

	/* distfiles */
	if (conf.distfiles_cache == NULL)
		return;

	snprintf(source, sizeof(source), "%s/usr/ports/distfiles", j->mountpoint);

	if (mkdir(source, 0755) != 0 && errno != EEXIST)
		err(1, "Unable to create dir: %s", source);

	iov[3].iov_base = source;
	iov[3].iov_len =  strlen(source) + 1;

	iov[5].iov_base = conf.distfiles_cache;
	iov[5].iov_len = strlen(conf.distfiles_cache) + 1;

	if (nmount(iov, 6, 0))
		err(1, "failed to mount %s\n", target);
}

int
mntcmp(const void *a, const void *b)
{
	return (strcmp((char*)a, (char *)b));
}

void
jail_stop(struct pjail *j)
{
	struct statfs *mntbuf;
	size_t mntsize, i, n;
	struct pjail *c;
	char snap[MAXPATHLEN];
	char **mnts;
	char *argv[5];

	if (!jail_runs(j->name)) {
		fprintf(stderr, "No such jail: %s\n", j->name);
		return;
	}

	STAILQ_FOREACH(c, &j->children, next)
		jail_kill(c);
	jail_kill(j);

	if ((mntsize = getmntinfo(&mntbuf, MNT_NOWAIT)) <= 0)
		err(EXIT_FAILURE, "Error while getting the list of mountpoints");

	mnts = malloc(mntsize * sizeof(char *));

	n = 0;
	for (i = 0; i < mntsize; i++) {
		if (strncmp(mntbuf[i].f_mntonname, j->mountpoint, strlen(j->mountpoint)) == 0)
			if (strlen(mntbuf[i].f_mntonname) > strlen(j->mountpoint)) {
				mnts[n] = mntbuf[i].f_mntonname;
				n++;
			}
	}

	qsort(mnts, n, sizeof(char *), mntcmp);

	for (i = 0; i < n; i++)
		unmount(mnts[i], MNT_FORCE);

	free(mnts);

	snprintf(snap, sizeof(snap), "%s@clean", j->fs);
	argv[0] = "zfs";
	argv[1] = "rollback";
	argv[2] = "-R";
	argv[3] = snap;
	argv[4] = NULL;

	if (exec("/sbin/zfs", argv) != 0)
		err(1, "Failed to rollback to %s", snap);
}

void
jail_setup(struct pjail *j)
{
	FILE *s,*t;
	char path[MAXPATHLEN];
	char dest[MAXPATHLEN];
	char buf[BUFSIZ];
	struct stat st;

	/* prepare the make.conf */
	snprintf(path, sizeof(path), "/usr/local/etc/poudriere.d/make.conf");
	snprintf(dest, sizeof(dest), "%s/etc/make.conf", j->mountpoint);

	lstat(path, &st);
	if (S_ISREG(st.st_mode) && (s = fopen(path, "r")) && (t = fopen(dest, "a+")) ) {
		while (fgets(buf, BUFSIZ, s) != NULL)
			fprintf(t, "%s", buf);
		fclose(t);
		fclose(s);
	}

	snprintf(path, sizeof(path), "/usr/local/etc/poudriere.d/%s-make.conf", j->name);

	lstat(path, &st);
	if (S_ISREG(st.st_mode) && (s = fopen(path, "r")) && (t = fopen(dest, "a+")) ) {
		while (fgets(buf, BUFSIZ, s) != NULL)
			fprintf(t, "%s", buf);
		fclose(t);
		fclose(s);
	}

	snprintf(dest, sizeof(dest), "%s/etc/resolv.conf", j->mountpoint);
	lstat(conf.resolv_conf, &st);
	if (S_ISREG(st.st_mode) && (s = fopen(conf.resolv_conf, "r")) && (t = fopen(dest, "a+")) ) {
		while (fgets(buf, BUFSIZ, s) != NULL)
			fprintf(t, "%s", buf);
		fclose(t);
		fclose(s);
	}
}