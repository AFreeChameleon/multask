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

void init_cgroup(char* exe_loc);

int main(int argc, char* argv[]) {
    char cwd[PATH_MAX];
    if (getcwd(cwd, sizeof(cwd)) == NULL) {
        printf("-1");
        return 1;
    }
    if (cwd[strlen(cwd) - 1] != '/') {
        strcat(cwd, "/");
    }
    char* exe = strtok(argv[0], "/");
    strcat(cwd, argv[0]);
    printf("%s %s\n", exe, cwd);
    init_cgroup(cwd);
}


void init_cgroup(char* exe_loc) {
    printf("Starting...\n");
    struct stat* stat_buf;
    stat(exe_loc, stat_buf);
    printf("userid: %d\n", stat_buf->st_uid);

    struct passwd* user = getpwuid(stat_buf->st_uid);
    printf("%d\n", user->pw_uid);
    int res = mkdir("/sys/fs/cgroup/mult", 0777);
    if (res != 0) {
        printf("%d\n", res);
        goto cleanup;
    }

    res = chown("/sys/fs/cgroup/mult", user->pw_uid, user->pw_gid);
    if (res != 0) {
        printf("%d\n", res);
        goto cleanup;
    }

    struct dirent* de;
    DIR* dr = opendir("/sys/fs/cgroup/mult");
    if (dr == NULL) {
        printf("Could not open dir.\n");
        goto cleanup;
    }

    while ((de = readdir(dr)) != NULL) {
        char mult_cgroup_dir[1024] = "/sys/fs/cgroup/mult/";
        strcat(mult_cgroup_dir, de->d_name);
        printf("%s\n", mult_cgroup_dir);
        chown(mult_cgroup_dir, user->pw_uid, user->pw_gid);
    }

cleanup:
    closedir(dr);
    free(user);
    return;
}

