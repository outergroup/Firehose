#define main firehose_main
#include "../Backend/main.c"
#undef main
#include <assert.h>
int main(int argc, char **argv) {
    assert(argc == 2);
    assert(!is_known_process_name("pid-3031757"));
    assert(is_known_process_name("pid-worker"));
    ProcessTimelineItem item = {0};
    strcpy(item.process, "pid-123");
    TraceEvent named_fork = {0};
    strcpy(named_fork.type, "process.fork");
    strcpy(named_fork.process, "worker");
    update_process_timeline_name(&item, &named_fork);
    assert(!strcmp(item.process, "worker"));
    strcpy(named_fork.type, "process.exit");
    strcpy(named_fork.process, "pid-123");
    update_process_timeline_name(&item, &named_fork);
    assert(!strcmp(item.process, "worker"));
    ProcessTimelineSnapshot grouped = {0};
    TraceEvent task_event = {.pid=101, .tgid=100, .timestamp=1};
    strcpy(task_event.process, "Thread-5");
    strcpy(task_event.group_name, "python");
    strcpy(task_event.type, "process.fork");
    assert(append_event_to_process_timeline_snapshot(&grouped, &task_event, 0));
    strcpy(task_event.type, "process.exit");
    task_event.timestamp=2;
    assert(append_event_to_process_timeline_snapshot(&grouped, &task_event, 1));
    assert(grouped.timeline.count==1);
    assert(grouped.timeline.items[0].pid==100);
    assert(!strcmp(grouped.timeline.items[0].process,"python"));
    assert(!grouped.timeline.items[0].has_start && !grouped.timeline.items[0].has_end);
    task_event.pid=100;
    task_event.timestamp=3;
    assert(append_event_to_process_timeline_snapshot(&grouped, &task_event, 2));
    assert(grouped.timeline.items[0].has_end);
    assert(grouped.timeline.items[0].event_count==3);
    clear_process_timeline_snapshot(&grouped);
    for (int fd = 0; fd < 100; fd++) fd_path_set(100, fd, "/test/parent/path");
    fd_path_copy_pid(100, 200);
    for (int fd = 0; fd < 100; fd++) assert(!strcmp(fd_path_find(200, fd)->path, "/test/parent/path"));
    assert(event_store_init(&g_events));
    TraceEvent event = {.id=1, .pid=123, .tgid=120, .group_name="owner", .cgroup_id=456, .container={.id="test-container", .name="Test café"}};
    strcpy(event.type, "process.exit");
    strcpy(event.process, "short-lived");
#ifdef __linux__
    container_groups=calloc(1,sizeof(*container_groups));
    assert(container_groups);
    container_groups[0]=(ContainerGroup){.inode=456,.context=event.container};
    container_group_count=1;
    ProcessInfo process={.pid=2147483647,.tgid=120,.group_name="owner",.cgroup_id=456};
    strcpy(process.name,"short-lived");
    add_event("process.exit",&process,"","");
    container_group_count=0;
    assert(read_event_at_chronological_index(0,&event));
    assert(!strcmp(event.container.id,"test-container"));
    free(container_groups); container_groups=NULL;
#else
    assert(write_all_fd(g_events.fd, &event, sizeof(event)));
    g_events.count = 1;
#endif
    EventFilter filter={0};
    append_filter_clause(&filter, "container", "equals", "test-container");
    assert(event_matches_filter(&event, &filter));
    unsigned char *binary=NULL;
    size_t size=build_events_binary(0, 10, true, &filter, &binary);
    assert(size > EVENT_BINARY_HEADER_SIZE + EVENT_BINARY_RECORD_SIZE);
    FILE *out=fopen(argv[1], "wb"); assert(out);
    assert(fwrite(binary,1,size,out)==size); fclose(out); free(binary);
    strcpy(filter.clauses[0].value, "host");
    assert(!event_matches_filter(&event, &filter));
    event_store_close(&g_events); free(g_fd_paths.items);
    puts("PASS fork path copying and stored container event filtering");
}
