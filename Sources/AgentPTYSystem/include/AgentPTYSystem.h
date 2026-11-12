#ifndef AGENT_PTY_SYSTEM_H
#define AGENT_PTY_SYSTEM_H

#include <stdint.h>
#include <sys/types.h>

typedef struct {
    pid_t pid;
    int master;
} AgentPTYHandle;

// argv includes the launch helper, the target path, and the target's argv.
int agent_pty_spawn(int directory, char *const argv[], char *const envp[],
                    uint16_t rows, uint16_t columns, AgentPTYHandle *handle);
int agent_pty_resize(int master, uint16_t rows, uint16_t columns);
// Returns 1 if exited and still waitable, 0 if running, or -errno.
int agent_pty_has_exited(pid_t pid);
// Returns 1 if reaped, 0 if still running, or -errno.
int agent_pty_reap(pid_t pid, int *exit_code);

#endif
