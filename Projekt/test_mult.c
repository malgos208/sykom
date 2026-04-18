#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

#define PROC_PATH "/proc/sykom/"

int main() {
    int fd_a1, fd_a2, fd_ctrl, fd_stat, fd_res;
    char buf[256];
    int n;

    fd_a1 = open(PROC_PATH "a1stma", O_WRONLY);
    fd_a2 = open(PROC_PATH "a2stma", O_WRONLY);
    fd_ctrl = open(PROC_PATH "ctstma", O_WRONLY);
    fd_stat = open(PROC_PATH "ststma", O_RDONLY);
    fd_res  = open(PROC_PATH "restma", O_RDONLY);

    if (fd_a1 < 0 || fd_a2 < 0 || fd_ctrl < 0 || fd_stat < 0 || fd_res < 0) {
        perror("open");
        return 1;
    }

    // Test 1: 2.5 * 4.0 = 10.0
    write(fd_a1, "2.5", 3);
    write(fd_a2, "4.0", 3);
    write(fd_ctrl, "1", 1);

    do {
        lseek(fd_stat, 0, SEEK_SET);
        n = read(fd_stat, buf, sizeof(buf)-1);
        buf[n] = '\0';
    } while (strncmp(buf, "done", 4) != 0);

    lseek(fd_res, 0, SEEK_SET);
    n = read(fd_res, buf, sizeof(buf)-1);
    buf[n] = '\0';
    printf("2.5 * 4.0 = %s\n", buf);

    // Test 2: -1.23e-4 * 5.67e8 = -69741
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
    printf("-1.23e-4 * 5.67e8 = %s\n", buf);

    close(fd_a1); close(fd_a2); close(fd_ctrl);
    close(fd_stat); close(fd_res);
    return 0;
}