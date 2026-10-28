#define main firehose_main
#include "../Backend/main.c"
#undef main
#include <assert.h>
int main(void) {
    setenv("OUTER_TRACING_CONTEXT_ID", "apple.container:test", 1);
    setenv("OUTER_TRACING_CONTEXT_NAME", "Test", 1);
    assert(event_store_init(&g_events));
    BPFKernelEvent fork = {.event_type=TRACE_BPF_EVENT_FORK, .pid=9000, .ppid=12300, .timestamp_ns=100, .cgroup_id=1};
    strcpy(fork.comm,"child");
    consume_kernel_event(fork,false);
    assert(g_events.count==0 && g_namespace_fork_count==1);
    BPFKernelEvent child = {.event_type=TRACE_BPF_EVENT_EXIT,.pid=12345,.tid=12345,.ppid=12340,.kernel_pid_tgid=9000,.timestamp_ns=200,.cgroup_id=1};
    strcpy(child.comm,"child");
    consume_kernel_event(child,false);
    assert(g_events.count==2 && g_namespace_fork_count==0);
    TraceEvent event;
    assert(read_event_at_chronological_index(0,&event));
    assert(event.pid==12345 && event.tgid==12340);
    assert(strstr(event.detail,"12300"));
    assert(!strcmp(event.container.id,"apple.container:test"));
    assert(read_event_at_chronological_index(1,&event));
    assert(event.pid==12345 && !strcmp(event.type,"process.exit"));
    assert(event_store_clear(&g_events));
    consume_kernel_event(child,false);
    consume_kernel_event(fork,false);
    assert(g_events.count==2 && g_namespace_fork_count==0);
    assert(read_event_at_chronological_index(1,&event));
    assert(event.pid==12345 && !strcmp(event.type,"process.fork"));
    fork.timestamp_ns=300;
    consume_kernel_event(fork,false);
    assert(g_events.count==2 && g_namespace_fork_count==1);
    child.timestamp_ns=400;child.pid=child.tid=12445;child.ppid=12440;
    consume_kernel_event(child,false);
    assert(g_events.count==4 && !g_namespace_fork_count);
    assert(read_event_at_chronological_index(2,&event));
    assert(event.pid==12445 && event.tgid==12440);
    event_store_clear(&g_events);event_store_close(&g_events);
    puts("PASS namespaced fork/exit IDs, out-of-order CPU delivery, and PID reuse");
}
