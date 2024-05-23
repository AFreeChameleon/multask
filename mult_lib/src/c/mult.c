#include <errno.h>
#include <linux/limits.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
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

    res = chown("/sys/fs/cgroup/mult", uid, gid);
    if (res != 0) {
        return errno;
    }

    struct dirent* de;
    DIR* dr = opendir("/sys/fs/cgroup/mult");
    if (dr == NULL) {
        return errno;
    }

    while ((de = readdir(dr)) != NULL) {
        char mult_cgroup_dir[1024] = "/sys/fs/cgroup/mult/";
        strcat(mult_cgroup_dir, de->d_name);
        chown(mult_cgroup_dir, uid, gid);
    }

    closedir(dr);
    return 0;
}

