#ifndef CONTAINER_CONTEXT_H
#define CONTAINER_CONTEXT_H
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <ctype.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <pthread.h>
#include <glob.h>
#include <errno.h>
#include <fcntl.h>

typedef struct {
    char id[65];
    char name[128];
    int local_pid;
} ContainerContext;
static ContainerContext container_host(void) {
    return (ContainerContext){.id="host", .name="Host"};
}
#ifdef __linux__
typedef struct { uint64_t inode; ContainerContext context; } ContainerGroup;
static ContainerContext container_names[1024];
static size_t container_name_count;
static ContainerGroup *container_groups;
static size_t container_group_count;
static pthread_mutex_t container_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t container_u32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}
static bool container_exact(int fd, void *data, size_t size) {
    while (size) {
        ssize_t n=read(fd,data,size);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) return false;
        data=(char *)data+n; size-=(size_t)n;
    }
    return true;
}
static bool container_string(const unsigned char *b, size_t size, size_t field, size_t variable, char *out, size_t cap) {
    size_t offset=container_u32(b+field), length=container_u32(b+field+4);
    if (offset<variable || offset>size || length>size-offset || length>=cap || memchr(b+offset,0,length)) return false;
    memcpy(out,b+offset,length); out[length]=0; return true;
}
static void container_registry(const char *path, ContainerContext *names, size_t *count) {
    struct sockaddr_un address={.sun_family=AF_UNIX};
    if (strlen(path)>=sizeof(address.sun_path)) return;
    strcpy(address.sun_path,path);
    int fd=socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0);
    if (fd<0) return;
    struct timeval timeout={.tv_sec=5};
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    unsigned char header[4], request[]={2,0,0,0,34,0};
    unsigned char *body=NULL;
    if (connect(fd,(struct sockaddr *)&address,sizeof(address)) || send(fd,request,sizeof(request),MSG_NOSIGNAL)!=sizeof(request) || !container_exact(fd,header,4)) goto done;
    size_t size=container_u32(header);
    if (size<48 || size>16*1024*1024) goto done;
    body=malloc(size);
    if (!body || !container_exact(fd,body,size)) goto done;
    size_t rows=container_u32(body+12), variable=container_u32(body+24);
    if (memcmp(body,"OSED",4) || container_u32(body+4)!=1 || container_u32(body+8)!=size || container_u32(body+16)!=72 || container_u32(body+20)!=48 || variable!=48+rows*72 || variable>size || container_u32(body+28)) goto done;
    for (size_t i=0;i<rows && *count<1024;i++) {
        ContainerContext context={0}; char runtime[64]; size_t row=48+i*72;
        if (!container_string(body,size,row+16,variable,runtime,sizeof(runtime)) || strcmp(runtime,"docker") ||
            !container_string(body,size,row+24,variable,context.id,sizeof(context.id)) || strlen(context.id)!=64 || strspn(context.id,"0123456789abcdef")!=64 ||
            !container_string(body,size,row+8,variable,context.name,sizeof(context.name))) continue;
        names[(*count)++]=context;
    }
done:
    free(body); close(fd);
}
static ContainerContext container_path_context(const char *path, const ContainerContext *names, size_t count) {
    ContainerContext context=container_host();
    for (size_t i=0;i<count;i++) if (strstr(path,names[i].id)) return names[i];
    for (const char *p=path;*p;p++) {
        size_t n=strspn(p,"0123456789abcdef");
        if (n==64) {
            memcpy(context.id,p,64); context.id[64]=0;
            snprintf(context.name,sizeof(context.name),"Container %.12s",context.id); return context;
        }
        if (n) p+=n-1;
    }
    return context;
}
static void container_scan(const char *path, ContainerGroup *groups, size_t *count, const ContainerContext *names, size_t names_count, unsigned depth) {
    if (depth>64 || *count>=16384) return;
    struct stat st;
    if (lstat(path,&st) || !S_ISDIR(st.st_mode)) return;
    groups[*count]=(ContainerGroup){.inode=(uint64_t)st.st_ino,.context=container_path_context(path,names,names_count)};
    (*count)++;
    DIR *dir=opendir(path); if (!dir) return;
    struct dirent *entry;
    while ((entry=readdir(dir))) {
        if (entry->d_name[0]=='.') continue;
        if (entry->d_type!=DT_DIR && entry->d_type!=DT_UNKNOWN) continue;
        char child[4096]; int n=snprintf(child,sizeof(child),"%s/%s",path,entry->d_name);
        if (n>0 && (size_t)n<sizeof(child)) container_scan(child,groups,count,names,names_count,depth+1);
    }
    closedir(dir);
}
static void *container_worker(void *unused) {
    (void)unused;
    for (;;) {
        ContainerContext *names=calloc(1024,sizeof(*names));
        ContainerGroup *groups=calloc(16384,sizeof(*groups));
        if (!names || !groups) { free(names); free(groups); sleep(5); continue; }
        size_t count=0, group_count=0;
        const char *override=getenv("OUTERSHELLD_API_SOCKET");
        char path[256];
        snprintf(path,sizeof(path),"/run/user/%u/outershelld-api",(unsigned)geteuid());
        container_registry(override && *override ? override : geteuid()==0 ? "/run/outershelld-api" : path,names,&count);
        if (geteuid()==0 && (!override || !*override || !strcmp(override,"/run/outershelld-api"))) {
            glob_t paths={0};
            if (!glob("/run/user/*/outershelld-api",0,NULL,&paths))
                for (size_t i=0;i<paths.gl_pathc;i++) container_registry(paths.gl_pathv[i],names,&count);
            globfree(&paths);
        }
        container_scan("/sys/fs/cgroup",groups,&group_count,names,count,0);
        pthread_mutex_lock(&container_lock);
        memcpy(container_names,names,count*sizeof(*names)); container_name_count=count;
        ContainerGroup *old=container_groups; container_groups=groups; container_group_count=group_count;
        pthread_mutex_unlock(&container_lock);
        free(old); free(names); sleep(5);
    }
    return NULL;
}
static void container_start(void) {
    pthread_t thread;
    int error=pthread_create(&thread,NULL,container_worker,NULL);
    if (error) fprintf(stderr,"Container discovery: %s\n",strerror(error));
    else pthread_detach(thread);
}
static ContainerContext container_for_cgroup(uint64_t id) {
    ContainerContext result={0};
    snprintf(result.id,sizeof(result.id),"cgroup-%llu",(unsigned long long)id);
    snprintf(result.name,sizeof(result.name),"Unresolved cgroup %llu",(unsigned long long)id);
    pthread_mutex_lock(&container_lock);
    for (size_t i=0;i<container_group_count;i++) if (container_groups[i].inode==id) { result=container_groups[i].context; break; }
    pthread_mutex_unlock(&container_lock);
    return result;
}
#endif
#ifndef __linux__
static void container_start(void) {}
#endif
static void container_put32(unsigned char *p, uint32_t value) {
    for (int i=0;i<4;i++) p[i]=(unsigned char)(value>>(8*i));
}
static unsigned char *container_catalog(size_t *size) {
    ContainerContext names[1025]; size_t count=1;
    names[0]=container_host();
#ifdef __linux__
    pthread_mutex_lock(&container_lock);
    memcpy(names+1,container_names,container_name_count*sizeof(*names)); count+=container_name_count;
    pthread_mutex_unlock(&container_lock);
#endif
    *size=16+count*16;
    for (size_t i=0;i<count;i++) *size+=strlen(names[i].id)+strlen(names[i].name);
    unsigned char *bytes=calloc(1,*size); if (!bytes) return NULL;
    memcpy(bytes,"CTXT",4); container_put32(bytes+4,1); container_put32(bytes+8,(uint32_t)*size); container_put32(bytes+12,(uint32_t)count);
    size_t offset=16+count*16;
    for (size_t i=0;i<count;i++) {
        const char *fields[]={names[i].id,names[i].name};
        for (size_t j=0;j<2;j++) {
            size_t n=strlen(fields[j]); container_put32(bytes+16+i*16+j*8,(uint32_t)offset); container_put32(bytes+20+i*16+j*8,(uint32_t)n);
            memcpy(bytes+offset,fields[j],n); offset+=n;
        }
    }
    return bytes;
}
#endif
