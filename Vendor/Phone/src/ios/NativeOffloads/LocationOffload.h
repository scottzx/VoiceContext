//
//  LocationOffload.h
//  MinisApp
//
//  Native offload handler for `apple-location` — CoreLocation.
//

#ifndef LocationOffload_h
#define LocationOffload_h

/// Register the apple-location native handler.
void location_offload_register(void);

/// Invoke the same native handler without launching a guest task.
int location_offload_execute_direct(int argc, char **argv, int stdout_fd, int stderr_fd);

#endif /* LocationOffload_h */
