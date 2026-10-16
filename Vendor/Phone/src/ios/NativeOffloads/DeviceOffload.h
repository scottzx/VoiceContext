//
//  DeviceOffload.h
//  MinisApp
//
//  Native offload handler for `apple-device` — UIDevice + ProcessInfo.
//

#ifndef DeviceOffload_h
#define DeviceOffload_h

/// Register the apple-device native handler.
void device_offload_register(void);

/// Invoke the same native handler without launching a guest task.
int device_offload_execute_direct(int argc, char **argv, int stdout_fd, int stderr_fd);

#endif /* DeviceOffload_h */
