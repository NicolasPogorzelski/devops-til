# JVM Heap (-Xmx) vs. Container Memory Limit

## Two limits, two enforcers

| Limit | Set by | Enforced by | When exceeded |
|---|---|---|---|
| Heap, `-Xmx` | `JAVA_OPTS` / `JAVA_TOOL_OPTIONS` | the JVM | garbage collection first; if still full, `OutOfMemoryError` inside the app |
| Container, `mem_limit` (cgroup `memory.max`) | Compose / Docker | the kernel | OOM killer terminates the process (exit 137), no application-level error |

They are not the same number, and the wrong relation between them produces
the worse failure mode.

## What the heap is not

The heap is only the object memory of the application. A running JVM also
needs:

- **Metaspace** - loaded classes (a Tomcat webapp like XWiki loads thousands).
- **Thread stacks** - ~1 MiB per thread by default, and servlet containers
  keep pools of 200+ threads.
- **Code cache** - JIT-compiled machine code.
- **Direct/native buffers** - NIO, compression, embedded search engines
  (Solr in XWiki's case).
- The JVM binary and shared libraries themselves.

Rule of thumb from operating Tomcat-based apps: container RSS ~ heap +
0.5-1 GiB. So `mem_limit` must be **larger than `-Xmx`**, with that head
room. In the lab: `-Xmx1536m`, measured 2.18 GiB after the first
installation, limit raised from 2.5 to 3 GiB.

## The failure modes

1. **`mem_limit` < heap + native overhead.** The JVM still believes it has
   room (its own accounting only sees the heap), keeps allocating, and the
   kernel kills the container. Symptom: container restarts with exit code
   137, no stack trace, nothing in the application log. Looks like a crash
   loop, is a sizing error.
2. **No `-Xmx` at all.** Modern JVMs (10+) are container-aware and default
   the max heap to 25 % of the cgroup limit - usually too small for a real
   webapp, and a silent dependency on whatever limit is set outside.
3. **Heap too small for the working set.** `OutOfMemoryError: Java heap
   space` in the app log, GC threads at 100 % CPU before that ("GC
   overhead"). Recoverable with a larger `-Xmx`, as long as the container
   limit grows with it.

## Why the JVM does not simply give memory back

Once the heap has grown up to `-Xmx` it stays reserved (some collectors
uncommit slowly, but that is not something to plan around). A JVM container
therefore sits at a steady RSS near heap + overhead after warm-up - the idle
number after installation is the number to size the limit against, not the
value right after start.

## Same idea outside Java

The pattern "process-internal limit vs. cgroup limit" appears elsewhere:

- Puma (Ruby): `workers x per-worker RSS` vs. container limit - GitLab
  Omnibus auto-sizes workers to CPU count, not to memory, so the container
  limit must follow the worker count or the worker count the limit.
- PostgreSQL: `shared_buffers` + `work_mem x connections` vs. limit.

In every case the internal knob decides how much the app *asks for*, the
cgroup decides what it *gets*; the two must be set together.

## Verification

```
docker stats --no-stream <container>          # MEM USAGE / LIMIT
docker inspect --format '{{.HostConfig.Memory}}' <container>   # limit in bytes, 0 = none
docker exec <container> sh -c 'ps -o rss,args -p 1'            # RSS of the JVM, compare with -Xmx
docker inspect --format '{{.State.ExitCode}}' <container>      # 137 after a kernel OOM kill
```
