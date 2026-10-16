//
//  RemindersOffload.h
//  MinisApp
//
//  Native offload handler for `apple-reminders` — EventKit reminders.
//

#ifndef RemindersOffload_h
#define RemindersOffload_h

/// Register the apple-reminders native handler.
void reminders_offload_register(void);

/// Invoke the same native handler without launching a guest task.
int reminders_offload_execute_direct(int argc, char **argv, int stdout_fd, int stderr_fd);

#endif /* RemindersOffload_h */
