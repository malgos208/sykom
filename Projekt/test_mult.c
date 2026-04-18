#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

int main() {
    int fd_a1, fd_a2, fd_ctrl, fd_stat, fd_res;
    char buf[256];
    int n;

    fd_a1 = open("/proc/sykom/a1stma", O_WRONLY);
    fd_a2 = open("/proc/sykom/a2stma", O_WRONLY);
    fd_ctrl = open("/proc/sykom/ctstma", O_WRONLY);
    fd_stat = open("/proc/sykom/ststma", O_RDONLY);
    fd_res  = open("/proc/sykom/restma", O_RDONLY);

    if (fd_a1 < 0 || fd_a2 < 0 || fd_ctrl < 0 || fd_stat < 0 || fd_res < 0) {
        perror("open");
        return 1;
    }

    // Test 1: 2.5e1 * 4.0e0 = 100
    write(fd_a1, "2.5e1", 5);
    write(fd_a2, "4.0e0", 5);
    write(fd_ctrl, "1", 1);

    do {
        lseek(fd_stat, 0, SEEK_SET);
        n = read(fd_stat, buf, sizeof(buf)-1);
        buf[n] = '\0';
    } while (strncmp(buf, "done", 4) != 0);

    lseek(fd_res, 0, SEEK_SET);
    n = read(fd_res, buf, sizeof(buf)-1);
    buf[n] = '\0';
    printf("Result 1: %s\n", buf);

    // Test 2: -1.23e-4 * 5.67e8 = -69741.0 (około)
    lseek(fd_a1, 0, SEEK_SET);
    lseek(fd_a2, 0, SEEK_SET);
    write(fd_a1, "-1.23e-4", 8);
    write(fd_a2, "5.67e8", 6);
    write(fd_ctrl, "1", 1);

    do {
        lseek(fd_stat, 0, SEEK_SET);
        n = read(fd_stat, buf, sizeof(buf)-1);
        buf[n] = '\0';
    } while (strncmp(buf, "done", 4) != 0);

    lseek(fd_res, 0, SEEK_SET);
    n = read(fd_res, buf, sizeof(buf)-1);
    buf[n] = '\0';
    printf("Result 2: %s\n", buf);

    close(fd_a1); close(fd_a2); close(fd_ctrl);
    close(fd_stat); close(fd_res);
    return 0;
}