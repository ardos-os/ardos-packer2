#include <stdio.h>
#include "hellolibrary.h"

int main(void) {
    printf("%s\n", hellolibrary_greeting());
    printf("2 + 3 = %d\n", hellolibrary_add(2, 3));
    return 0;
}
