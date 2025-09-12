void* profiler_init();
void profiler_deinit(void *profiler);
void* profiler_scope_start(void *profiler, char *name);
void profiler_scope_end(void *profiler, void *scope);
int profiler_save(void *profiler, char *path);
