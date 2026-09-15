#include <stdio.h>
#include <string.h>
#include <stdlib.h>
static const char* names[] = {"zero", "one", "two"};
int main(void)
    {
    char buf[32];
    strcpy(buf, names[2]);
    strcat(buf, "-"
                "three");
    printf("%s %d %d\n", buf, (int)strlen(buf), strcmp(buf, "two-three"));
    char* m = malloc(8);
    memset(m, 'x', 7);
    m[7] = 0;
    printf("%s\n", m);
    free(m);
    const char* esc = "\033[0m\t|";
    printf("%d %d %c\n", esc[0], esc[4], esc[5]);
    unsigned char hi[] = "\xff\x80";
    printf("%d %d\n", hi[0], hi[1]);
    char c = 'a';
    c += 2;
    printf("%c %d\n", c, 'z' - c);
    return 0;
    }
