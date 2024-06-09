#include <errno.h>
#include <linux/limits.h>
#include <unistd.h>
#include <pwd.h>
#include <dirent.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include "cpulimit/cpulimit.h"

void limit_process(pid_t pid, double limit, int include_children);
