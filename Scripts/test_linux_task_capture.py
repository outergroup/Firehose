#!/usr/bin/env python3
import http.client, os, pathlib, socket, struct, subprocess, sys, tempfile, time
class Connection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__('localhost', timeout=30); self.path=str(path)
    def connect(self):
        self.sock=socket.socket(socket.AF_UNIX); self.sock.settimeout(30); self.sock.connect(self.path)
def get(path, url):
    c=Connection(path); c.request('GET',url); r=c.getresponse(); data=r.read(); c.close()
    assert r.status==200,(r.status,data)
    return data
def u32(b,o):return struct.unpack_from('<I',b,o)[0]
def u64(b,o):return struct.unpack_from('<Q',b,o)[0]
def text(b,o):
    start,size=struct.unpack_from('<II',b,o);return b[start:start+size].decode()
with tempfile.TemporaryDirectory(prefix='firehose-task-test-') as directory:
    work=pathlib.Path(directory)
    (work/'fixture.c').write_text(r'''
#include <pthread.h>
#include <stdio.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
static void *worker(void *unused) {
    prctl(PR_SET_NAME,"fh-worker");
    printf("%ld\n",syscall(SYS_gettid));
    int fd=open("/dev/null",O_WRONLY);write(fd,"x",1);close(fd);
    return NULL;
}
int main(void) {
    prctl(PR_SET_NAME,"fh-task-test");
    printf("%d\n",getpid());fflush(stdout);
    for(int i=0;i<5;i++){pthread_t t;pthread_create(&t,NULL,worker,NULL);pthread_join(t,NULL);}
    for(int i=0;i<5;i++){pid_t p=fork();if(!p)_exit(0);printf("%d\n",p);waitpid(p,NULL,0);}
    return 0;
}
''')
    subprocess.run(['cc',str(work/'fixture.c'),'-lpthread','-o',str(work/'fixture')],check=True)
    with (work/'backend.log').open('w+') as log:
        backend=subprocess.Popen([sys.argv[1],'--socket-path',str(work/'api.sock')],env=dict(os.environ,HOME=str(work),OUTERSHELL_SERVICE_STATE_DIR=str(work/'state')),stdout=log,stderr=log)
        try:
            for _ in range(100):
                if (work/'api.sock').exists():break
                assert backend.poll() is None
                time.sleep(.1)
            ids=list(map(int,subprocess.check_output([str(work/'fixture')],text=True).split()))
            time.sleep(1)
            get(work/'api.sock','/api/capture?paused=1')
            for index,pid in enumerate(ids):
                query=f'filterCount=1&f0column=pid&f0op=equals&f0value={pid}'
                b=get(work/'api.sock','/api/events?count=512&'+query)
                assert not(u32(b,40)&8),'eBPF capture unavailable'
                rows=[(text(b,o+32),text(b,o+40)) for o in [72+i*u32(b,28) for i in range(u32(b,24))]]
                assert rows,(pid,rows)
                for i in range(u32(b,24)):
                    o=72+i*u32(b,28)
                    assert u32(b,o+88)==(ids[0] if 1<=index<=5 else pid), (pid, text(b,o+32), u32(b,o+88))
                    assert text(b,o+96), 'owning process name missing'
                if index:
                    assert any(t=='process.fork' and n=='fh-task-test' for t,n in rows),(pid,rows)
                assert sum(t=='process.exit' for t,n in rows)==1,(pid,rows)
                if 1<=index<=5:
                    assert any(t=='file.openat' and n=='fh-worker' for t,n in rows),(pid,rows)
                assert not any(n.startswith('pid-') for t,n in rows),(pid,rows)
            timeline=get(work/'api.sock','/api/processes')
            timeline_ids=[u32(timeline,64+i*u32(timeline,28)) for i in range(u32(timeline,24))]
            assert ids[0] in timeline_ids
            assert not set(ids[1:6]).intersection(timeline_ids), 'worker threads must not have process rows'
            assert set(ids[6:]).issubset(timeline_ids), 'child processes must retain their rows'
            print('PASS process timeline groups worker threads and preserves child processes')
            print('PASS live kernel capture: fork names, short-lived children, per-thread file events and exactly one exit per task')
        finally:
            backend.terminate()
            try:backend.wait(timeout=5)
            except subprocess.TimeoutExpired:backend.kill();backend.wait()
            log.seek(0);print(log.read()[-2000:])
