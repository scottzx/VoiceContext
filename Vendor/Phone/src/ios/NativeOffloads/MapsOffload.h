//
//  MapsOffload.h
//  MinisApp
//
//  Native offload handler for `apple-maps` — MapKit framework.
//

#ifndef MapsOffload_h
#define MapsOffload_h

/// Register the apple-maps native handler.
void maps_offload_register(void);

/// Invoke the same native handler without launching a guest task.
int maps_offload_execute_direct(int argc, char **argv, int stdout_fd, int stderr_fd);

#endif /* MapsOffload_h */
