#include <errno.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>

enum { status_fd = 3 };

int main(int argc, char **argv, char **envp) {
    int error = EINVAL;
    if (argc >= 3) {
        if (fcntl(status_fd, F_SETFD, FD_CLOEXEC) == 0 &&
            ioctl(STDIN_FILENO, TIOCSCTTY, 0) == 0) {
            execve(argv[1], argv + 2, envp);
        }
        error = errno;
    }

    // The parent treats EOF as a successful exec.
    while (write(status_fd, &error, sizeof(error)) == -1 && errno == EINTR) {}
    return 126;
}
