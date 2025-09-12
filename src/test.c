#include "anne_profiler.h"

int main(int argc, char **argv) {
    void *profiler = profiler_init();

    void *scope = profiler_scope_start(profiler, "test_scope2");
    profiler_scope_end(profiler, scope);

    profiler_deinit(profiler);
    return 0;
}
