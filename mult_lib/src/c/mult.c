#include <errno.h>
#include <linux/limits.h>
#include <unistd.h>
#include <pwd.h>
#include <dirent.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>

int init_cgroup(uid_t uid, gid_t gid) {
    int res = mkdir("/sys/fs/cgroup/mult", 0777);
    if (res != 0) {
        return errno;
    }

    //res = chown("/sys/fs/cgroup/mult", uid, gid);
    res = chmod("/sys/fs/cgroup/mult", 0777);
    if (res != 0) {
        return errno;
    }

    return 0;
}

