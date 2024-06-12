#include <sys/types.h>

void limit_process(pid_t pid, double limit, int include_children);
void set_cpu_limit(struct limit_params limit_p);
