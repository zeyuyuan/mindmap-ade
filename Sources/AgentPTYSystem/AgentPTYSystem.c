#include "AgentPTYSystem.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

enum { child_status_fd = 3 };

static int prepare_descriptor(int *fd) {
    // Keep the PTY and status pipe clear of the child's remapping targets.
    int duplicate = fcntl(*fd, F_DUPFD_CLOEXEC, child_status_fd + 1);
    if (duplicate < 0) return errno;
    close(*fd);
    *fd = duplicate;
    return 0;
}

static int open_master(int *master) {
    // Darwin can hand concurrent /dev/ptmx opens the same clone number.
    // Serialize the allocation and retry collisions with other processes.
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    for (int attempt = 0; attempt < 4; ++attempt) {
        pthread_mutex_lock(&lock);
        *master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC | O_NONBLOCK);
        int error = errno;
        pthread_mutex_unlock(&lock);
        if (*master >= 0) return 0;
        if (error != ENXIO && error != -ENXIO && error != EINTR) return error;
        usleep(1000);
    }
    return ENXIO;
}

static int open_terminal(int *master, int *slave, uint16_t rows, uint16_t columns) {
    int error = open_master(master);
    if (error != 0) return error;

    // Darwin's ptsname uses shared storage. Query the device into our own
    // buffer so concurrent starts cannot open one another's slave.
    char path[128];
    if (grantpt(*master) < 0 || unlockpt(*master) < 0 ||
        ioctl(*master, TIOCPTYGNAME, path) < 0) {
        error = errno;
    } else {
        *slave = open(path, O_RDWR | O_NOCTTY | O_CLOEXEC);
        if (*slave < 0) error = errno;
    }
    if (error == 0 && agent_pty_resize(*slave, rows, columns) < 0) error = errno;
    if (error != 0) {
        if (*slave >= 0) close(*slave);
        close(*master);
    }
    return error;
}

static int spawn_child(int directory, char *const argv[], char *const envp[],
                       int slave, int status_writer, pid_t *pid) {
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int result = posix_spawn_file_actions_init(&actions);
    if (result != 0) return result;
    result = posix_spawnattr_init(&attributes);
    if (result != 0) {
        posix_spawn_file_actions_destroy(&actions);
        return result;
    }

    sigset_t defaults, mask;
    sigfillset(&defaults);
    sigdelset(&defaults, SIGKILL);
    sigdelset(&defaults, SIGSTOP);
    sigemptyset(&mask);
    short flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT |
                  POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;

    result = posix_spawnattr_setflags(&attributes, flags);
    if (result == 0) result = posix_spawnattr_setsigdefault(&attributes, &defaults);
    if (result == 0) result = posix_spawnattr_setsigmask(&attributes, &mask);
    // Change directory before remapping fd 3, which may be the caller's directory fd.
    if (result == 0) result = posix_spawn_file_actions_addfchdir(&actions, directory);
    for (int fd = 0; result == 0 && fd <= STDERR_FILENO; ++fd) {
        result = posix_spawn_file_actions_adddup2(&actions, slave, fd);
    }
    if (result == 0) {
        result = posix_spawn_file_actions_adddup2(&actions, status_writer, child_status_fd);
    }
    if (result == 0) result = posix_spawn(pid, argv[0], &actions, &attributes, argv, envp);

    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    return result;
}

static int await_exec(int fd) {
    struct pollfd ready = {.fd = fd, .events = POLLIN};
    int result;
    do { result = poll(&ready, 1, 2000); } while (result < 0 && errno == EINTR);
    if (result == 0) return ETIMEDOUT;
    if (result < 0) return errno;
    int child_error;
    ssize_t count;
    do { count = read(fd, &child_error, sizeof(child_error)); } while (count < 0 && errno == EINTR);
    if (count < 0) return errno;
    if (count == 0) return 0;
    return count == sizeof(child_error) ? child_error : EIO;
}

int agent_pty_spawn(int directory, char *const argv[], char *const envp[],
                    uint16_t rows, uint16_t columns, AgentPTYHandle *handle) {
    int master = -1, slave = -1;
    int error = open_terminal(&master, &slave, rows, columns);
    if (error != 0) return error;

    int status[2] = {-1, -1};
    error = prepare_descriptor(&master);
    if (error == 0) error = prepare_descriptor(&slave);
    if (error == 0 && pipe(status) != 0) error = errno;
    if (error == 0) error = prepare_descriptor(&status[0]);
    if (error == 0) error = prepare_descriptor(&status[1]);

    pid_t pid;
    if (error == 0) error = spawn_child(directory, argv, envp, slave, status[1], &pid);
    close(slave);
    if (status[1] >= 0) close(status[1]);
    if (error == 0) {
        error = await_exec(status[0]);
        if (error != 0) {
            kill(pid, SIGKILL);
            while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
        }
    }
    if (status[0] >= 0) close(status[0]);
    if (error != 0) {
        close(master);
        return error;
    }

    *handle = (AgentPTYHandle){.pid = pid, .master = master};
    return 0;
}

int agent_pty_resize(int master, uint16_t rows, uint16_t columns) {
    struct winsize size = {.ws_row = rows, .ws_col = columns};
    return ioctl(master, TIOCSWINSZ, &size);
}

int agent_pty_has_exited(pid_t pid) {
    siginfo_t info = {0};
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) < 0) return -errno;
    return info.si_pid == pid;
}

int agent_pty_reap(pid_t pid, int *exit_code) {
    int status;
    pid_t result = waitpid(pid, &status, WNOHANG);
    if (result < 0) return -errno;
    if (result == 0) return 0;
    *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    return 1;
}
