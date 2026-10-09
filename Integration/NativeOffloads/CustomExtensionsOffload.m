#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"

#if __has_include("Minis-Swift.h")
#import "Minis-Swift.h"
#else
@interface CustomExtensionsOffloadBridge : NSObject
+ (NSDictionary * _Nonnull)executeWithArguments:(NSArray<NSString *> * _Nonnull)arguments;
@end
#endif

static NSString *const HELP_TEXT =
    @"yima-extensions - Manage Yima custom function shortcuts\n"
     "\n"
     "USAGE:\n"
     "  yima-extensions <command> [options]\n"
     "\n"
     "COMMANDS:\n"
     "  list                                  List shortcuts in display order\n"
     "  get --id <uuid>                        Read one shortcut\n"
     "  add --name <name> --url <url>           Add an HTTP/HTTPS shortcut\n"
     "  update --id <uuid> [--name <name>] [--url <url>] [--clear-logo]\n"
     "                                        Update fields; retain the logo by default\n"
     "  move --id <uuid> --position <n>         Move to a zero-based final position\n"
     "  delete --id <uuid>                     Delete one shortcut\n"
     "\n"
     "GLOBAL OPTIONS:\n"
     "  --help, -h                            Show this help\n"
     "  --compact                             Minimize JSON output\n"
     "  -q, --quiet                           Output only data or error\n"
     "\n"
     "URLs must include http:// or https:// and any required port.\n"
     "localhost refers to this iPhone; use a reachable LAN or Tailscale address\n"
     "for a service hosted on another device. Saving a shortcut does not start\n"
     "its service. New shortcuts use their name's first character as the icon.\n";

static int custom_extensions_handler(int argc, char **argv,
                                     int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");
    NSMutableArray<NSString *> *arguments = [NSMutableArray array];
    for (int i = 1; i < argc; i++) {
        [arguments addObject:[NSString stringWithUTF8String:argv[i]]];
    }
    NSDictionary *result = noff_dispatch_main_sync(^id {
        return [CustomExtensionsOffloadBridge executeWithArguments:arguments];
    });
    noff_emit_json(stdout_fd, result[@"envelope"], compact, quiet);
    return [result[@"exit_code"] intValue];
}

void yima_extensions_offload_register(void) {
    int err = native_offload_add_handler("yima-extensions", custom_extensions_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/yima-extensions");
        NSLog(@"NativeOffloads: yima-extensions handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register yima-extensions handler (err=%d)", err);
    }
}
