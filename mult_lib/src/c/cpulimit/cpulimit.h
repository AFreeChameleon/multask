#include <sys/types.h>

struct limit_params {
    pid_t pid;
	int perclimit;
};

void limit_process(pid_t pid, double limit, int include_children);
void set_cpu_limit(pid_t pid, int perclimit);
