#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <pwd.h>
#include <dirent.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>

void init_cgroup() {
    printf("Starting...\n");
    struct passwd* user = getpwnam("bean");
    int res = mkdir("/sys/fs/cgroup/mult", 0777);
    if (res != 0) {
        printf("%d\n", res);
        return;
    }

    res = chown("/sys/fs/cgroup/mult", user->pw_uid, user->pw_gid);
    if (res != 0) {
        printf("%d\n", res);
        return;
    }

    struct dirent* de;
    DIR* dr = opendir("/sys/fs/cgroup/mult");
    if (dr == NULL) {
        printf("Could not open dir.\n");
        return;
    }

    while ((de = readdir(dr)) != NULL) {
        char mult_cgroup_dir[1024] = "/sys/fs/cgroup/mult/";
        strcat(mult_cgroup_dir, de->d_name);
        printf("%s\n", mult_cgroup_dir);
        chown(mult_cgroup_dir, user->pw_uid, user->pw_gid);
    }

    closedir(dr);
}

int main(void) {
    init_cgroup();
}

