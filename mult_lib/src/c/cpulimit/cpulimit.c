/**
 *
 * cpulimit - a CPU limiter for Linux
 *
 * Copyright (C) 2005-2012, by:  Angelo Marletta <angelo dot marletta at gmail dot com> 
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 *
 **************************************************************
 *
 * This is a simple program to limit the cpu usage of a process
 * If you modify this code, send me a copy please
 *
 * Get the latest version at: http://github.com/opsengine/cpulimit
 *
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <getopt.h>
#include <time.h>
#include <signal.h>
#include <string.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include "cpulimit.h"

#ifdef __APPLE__ || __FREEBSD__
#include <libgen.h>
#include <sys/sysctl.h>
#endif

#include "process_group.h"
#include "list.h"

#ifdef HAVE_SYS_SYSINFO_H
#include <sys/sysinfo.h>
#endif

#ifdef __APPLE__
#include "memrchr.c"
#endif

//some useful macro
#ifndef MIN
#define MIN(a,b) (((a)<(b))?(a):(b))
#endif
#ifndef MAX
#define MAX(a,b) (((a)>(b))?(a):(b))
#endif

//control time slot in microseconds
//each slot is splitted in a working slice and a sleeping slice
//TODO: make it adaptive, based on the actual system load
#define TIME_SLOT 100000

#define MAX_PRIORITY -10

/* GLOBAL VARIABLES */

//the "family"
static struct process_group pgroup;

//SIGINT and SIGTERM signal handler
static void quit(int sig)
{
    //let all the processes continue if stopped
    struct list_node *node = NULL;
    if (pgroup.proclist != NULL)
    {
        for (node = pgroup.proclist->first; node != NULL; node = node->next) {
            struct process *p = (struct process*)(node->data);
            kill(p->pid, SIGCONT);
        }
        close_process_group(&pgroup);
    }
    //fix ^C little problem
    printf("\r");
    exit(0);
}

//return t1-t2 in microseconds (no overflow checks, so better watch out!)
static inline unsigned long timediff(const struct timeval *t1,const struct timeval *t2)
{
	return (t1->tv_sec - t2->tv_sec) * 1000000 + (t1->tv_usec - t2->tv_usec);
}

static void increase_priority() {
	//find the best available nice value
	int old_priority = getpriority(PRIO_PROCESS, 0);
	int priority = old_priority;
	while (setpriority(PRIO_PROCESS, 0, priority-1) == 0 && priority>MAX_PRIORITY) {
		priority--;	
	}
}

int get_pid_max()
{
#ifdef __linux__
	//read /proc/sys/kernel/pid_max
	static char buffer[1024];
	FILE *fd = fopen("/proc/sys/kernel/pid_max", "r");
	if (fd==NULL) return -1;
	if (fgets(buffer, sizeof(buffer), fd)==NULL) {
		fclose(fd);
		return -1;
	}
	fclose(fd);
	return atoi(buffer);
#elif defined __FreeBSD__
	return 99998;
#elif defined __APPLE__
	return 99998;
#endif
}

void limit_process(pid_t pid, double limit, int include_children)
{
	//slice of the slot in which the process is allowed to run
	struct timespec twork;
	//slice of the slot in which the process is stopped
	struct timespec tsleep;
	//when the last twork has started
	struct timeval startwork;
	//when the last twork has finished
	struct timeval endwork;
	//initialization
	memset(&twork, 0, sizeof(struct timespec));
	memset(&tsleep, 0, sizeof(struct timespec));
	memset(&startwork, 0, sizeof(struct timeval));
	memset(&endwork, 0, sizeof(struct timeval));	
	//last working time in microseconds
	unsigned long workingtime = 0;
	//generic list item
	struct list_node *node;
	//counter
	int c = 0;

	//get a better priority
	increase_priority();
	
	//build the family
	init_process_group(&pgroup, pid, include_children);

	//rate at which we are keeping active the processes (range 0-1)
	//1 means that the process are using all the twork slice
	double workingrate = -1;
	while(1) {
		update_process_group(&pgroup);

		if (pgroup.proclist->count==0) {
			break;
		}
		
		//total cpu actual usage (range 0-1)
		//1 means that the processes are using 100% cpu
		double pcpu = -1;

		//estimate how much the controlled processes are using the cpu in the working interval
		for (node = pgroup.proclist->first; node != NULL; node = node->next) {
			struct process *proc = (struct process*)(node->data);
			if (proc->cpu_usage < 0) {
				continue;
			}
			if (pcpu < 0) pcpu = 0;
			pcpu += proc->cpu_usage;
		}

		//adjust work and sleep time slices
		if (pcpu < 0) {
			//it's the 1st cycle, initialize workingrate
			pcpu = limit;
			workingrate = limit;
			twork.tv_nsec = TIME_SLOT * limit * 1000;
		}
		else {
			//adjust workingrate
			workingrate = MIN(workingrate / pcpu * limit, 1);
			twork.tv_nsec = TIME_SLOT * 1000 * workingrate;
		}
		tsleep.tv_nsec = TIME_SLOT * 1000 - twork.tv_nsec;

		//resume processes
		node = pgroup.proclist->first;
		while (node != NULL)
		{
			struct list_node *next_node = node->next;
			struct process *proc = (struct process*)(node->data);
			if (kill(proc->pid,SIGCONT) != 0) {
				//process is dead, remove it from family
				//remove process from group
				delete_node(pgroup.proclist, node);
				remove_process(&pgroup, proc->pid);
			}
			node = next_node;
		}

		//now processes are free to run (same working slice for all)
		gettimeofday(&startwork, NULL);
		nanosleep(&twork, NULL);
		gettimeofday(&endwork, NULL);
		workingtime = timediff(&endwork, &startwork);
		
		long delay = workingtime - twork.tv_nsec/1000;

		if (tsleep.tv_nsec>0) {
			//stop processes only if tsleep>0
			node = pgroup.proclist->first;
			while (node != NULL)
			{
				struct list_node *next_node = node->next;
				struct process *proc = (struct process*)(node->data);
				if (kill(proc->pid,SIGSTOP)!=0) {
					//process is dead, remove it from family
					//remove process from group
					delete_node(pgroup.proclist, node);
					remove_process(&pgroup, proc->pid);
				}
				node = next_node;
			}
			//now the processes are sleeping
			nanosleep(&tsleep,NULL);
		}
		c++;
	}
	close_process_group(&pgroup);
}


void set_cpu_limit(pid_t pid, int perclimit) {
	double limit = perclimit / 100.0;

	//all arguments are ok!
	signal(SIGINT, quit);
	signal(SIGTERM, quit);

    pid_t ret = 0;
    //search by pid
    ret = find_process_by_pid(pid);
    if (ret == 0) {
        printf("No process found\n");
    } else if (ret < 0) {
        printf("Process found but you aren't allowed to control it\n");
    }
    if (ret > 0) {
        //control
        limit_process(pid, limit, 1);
    }
}

