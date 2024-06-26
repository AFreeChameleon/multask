#include "cpulimit/cpulimit.h"

void mult_set_cpu_limit(pid_t pid, int perclimit) {
    set_cpu_limit(pid, perclimit);
}
