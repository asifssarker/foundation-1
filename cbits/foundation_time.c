#include "foundation_system.h"

#ifdef FOUNDATION_SYSTEM_API_NO_CLOCK

#ifdef FOUNDATION_SYSTEM_MACOS
#include <time.h>
#include <mach/clock.h>
#include <mach/mach.h>
#include <mach/mach_time.h>

/* OSX MONOTONIC COMPAT:
 * http://web.archive.org/web/20100517095152/http://www.wand.net.nz/~smr26/wordpress/2009/01/19/monotonic-time-in-mac-os-x/comment-page-1/
 */


typedef enum {
	CLOCK_REALTIME,
	CLOCK_MONOTONIC,
	CLOCK_PROCESS_CPUTIME_ID,
	CLOCK_THREAD_CPUTIME_ID
} clockid_t;


static mach_timebase_info_data_t timebase = {0,0};  

int foundation_time_clock_getres(unsigned int clockid, struct timespec *timespec)
{
	switch (clockid) {
	/* clockid = 1 (CLOCK_MONOTONIC), or any other value */
	case CLOCK_MONOTONIC:
		if (timebase.denom == 0) mach_timebase_info(timebase); 
		timespec->tv_sec = 0;
		timespec->tv_nsec = timebase.numer / timebase.denom;
		break;
	/* clockid = 0 (CLOCK_REALTIME), or any other value */
	case CLOCK_REALTIME:
		return -1;
	}
	return -1;
}

int foundation_time_clock_gettime(unsigned int clockid, struct timespec *timespec)
{
	clock_serv_t cclock;
	mach_timespec_t mts;

	switch (clockid) {
#if 0
	case CLOCK_MONOTONIC: {
		uint64_t t, nanos;
		if (timebase.denom == 0) mach_timebase_info(timebase); 

		t = mach_absolute_time();
		nanos = t * (timebase.numer / timebase.denom);

		timespec->tv_sec = t / 1e9;
		timespec->tv_nsec = t % 1e9;
		break;
	case CLOCK_PROCESS_CPUTIME_ID:
		break;
#endif
	case CLOCK_MONOTONIC:
		host_get_clock_service(mach_host_self(), SYSTEM_CLOCK, &cclock);
		clock_get_time(cclock, &mts);
		mach_port_deallocate(mach_task_self(), cclock);
		timespec->tv_sec = mts.tv_sec;
		timespec->tv_nsec = mts.tv_nsec;
		break;
	case CLOCK_REALTIME:
		host_get_clock_service(mach_host_self(), CALENDAR_CLOCK, &cclock);
		clock_get_time(cclock, &mts);
		mach_port_deallocate(mach_task_self(), cclock);
		timespec->tv_sec = mts.tv_sec;
		timespec->tv_nsec = mts.tv_nsec;
		break;
	default:
		-1;
	}
	return 0;
}

#endif

#endif
