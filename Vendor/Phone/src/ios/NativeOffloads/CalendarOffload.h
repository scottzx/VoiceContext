//
//  CalendarOffload.h
//  MinisApp
//
//  Native offload handler for `apple-calendar` — EventKit events & reminders.
//

#ifndef CalendarOffload_h
#define CalendarOffload_h

#import <Foundation/Foundation.h>

/// Register the apple-calendar native handler.
void calendar_offload_register(void);

/// Invoke the same native handler without launching a guest task.
int calendar_offload_execute_direct(int argc, char **argv, int stdout_fd, int stderr_fd);

/// Shared reminder subcommand handlers (used by apple-reminders offload).
int calendar_cmd_reminders(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet);
int calendar_cmd_remind(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet);
int calendar_cmd_update_reminder(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet);
int calendar_cmd_complete_reminder(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet);
int calendar_cmd_delete_reminder(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet);

#endif /* CalendarOffload_h */
