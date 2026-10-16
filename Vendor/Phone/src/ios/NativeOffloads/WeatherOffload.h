//
//  WeatherOffload.h
//  MinisApp
//
//  Native offload handler for `apple-weather` — WeatherKit.
//

#ifndef WeatherOffload_h
#define WeatherOffload_h

/// Register the apple-weather native handler.
void weather_offload_register(void);

/// Invoke the same native handler without launching a guest task.
int weather_offload_execute_direct(int argc, char **argv, int stdout_fd, int stderr_fd);

#endif /* WeatherOffload_h */
