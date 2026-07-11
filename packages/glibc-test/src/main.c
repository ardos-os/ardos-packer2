#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <pwd.h>
#include <grp.h>
#include <unistd.h>
#include <locale.h>
#include <fcntl.h>

static int tests_run = 0;
static int tests_passed = 0;

static void check(const char *name, int ok) {
    tests_run++;
    if (ok) {
        tests_passed++;
        printf("%s OK\n", name);
    } else {
        printf("%s FAIL\n", name);
    }
}

int main(int argc, char *argv[]) {
    int skip_nss = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--no-nss") == 0)
            skip_nss = 1;
    }

    setlocale(LC_ALL, "C");

    if (!skip_nss) {
        /* Direct file open test — does proot translate /etc/passwd? */
        int fd = open("/etc/passwd", O_RDONLY);
        if (fd >= 0) {
            char buf[256];
            ssize_t n = read(fd, buf, sizeof(buf) - 1);
            close(fd);
            if (n > 0) {
                buf[n] = '\0';
                /* Print first line so we can see which /etc/passwd is being read */
                char *nl = memchr(buf, '\n', n);
                if (nl) *nl = '\0';
                fprintf(stderr, "FILETEST first_line=%s\n", buf);
            }
        } else {
            fprintf(stderr, "FILETEST open_failed errno=%d\n", errno);
        }

        errno = 0;
        struct passwd *pw = getpwnam("root");
        if (pw == NULL) {
            fprintf(stderr, "DEBUG getpwnam_root NULL errno=%d\n", errno);
        } else {
            fprintf(stderr, "DEBUG getpwnam_root name=%s uid=%d gid=%d shell=%s home=%s\n",
                    pw->pw_name, (int)pw->pw_uid, (int)pw->pw_gid, pw->pw_shell, pw->pw_dir);
        }
        check("getpwnam_root", pw != NULL
              && strcmp(pw->pw_name, "root") == 0
              && pw->pw_uid == 0
              && pw->pw_gid == 0
              && strcmp(pw->pw_shell, "/bin/sh") == 0);

        errno = 0;
        struct passwd *pw2 = getpwnam("nonexistent");
        check("getpwnam_miss", pw2 == NULL);

        errno = 0;
        struct group *gr = getgrnam("root");
        if (gr == NULL) {
            fprintf(stderr, "DEBUG getgrnam_root NULL errno=%d\n", errno);
        } else {
            fprintf(stderr, "DEBUG getgrnam_root name=%s gid=%d\n",
                    gr->gr_name, (int)gr->gr_gid);
        }
        check("getgrnam_root", gr != NULL
              && strcmp(gr->gr_name, "root") == 0
              && gr->gr_gid == 0);

        errno = 0;
        struct group *gr2 = getgrnam("nonexistent");
        check("getgrnam_miss", gr2 == NULL);
    }

    uid_t uid = getuid();
    uid_t euid = geteuid();
    check("getuid", uid == euid);

    const char *loc = setlocale(LC_ALL, "C");
    check("setlocale", loc != NULL);

    struct lconv *lc = localeconv();
    check("localeconv", lc != NULL && lc->decimal_point != NULL);

    printf("\n%d/%d tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
