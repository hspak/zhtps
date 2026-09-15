"""Bounded open-loop HTTP load driver. Reports errors and scheduled-time latency."""

import argparse
import asyncio
import collections
import json
import math
import time


def distribution(samples):
    ordered = sorted(samples)
    if not ordered:
        return {"count": 0}
    result = {"count": len(ordered), "max_ms": ordered[-1] * 1000}
    for label, fraction in (("p50_ms", 0.5), ("p95_ms", 0.95), ("p99_ms", 0.99)):
        result[label] = ordered[math.ceil(len(ordered) * fraction) - 1] * 1000
    return result


async def run(options):
    jobs = asyncio.Queue(maxsize=options.queue)
    statuses = collections.Counter()
    failures = collections.Counter()
    latency = collections.defaultdict(list)
    scheduler_lag = []
    dropped = 0
    request = (f"GET {options.path} HTTP/1.1\r\nHost: {options.host}\r\n\r\n").encode("ascii")
    loop = asyncio.get_running_loop()

    async def worker():
        reader = writer = None
        while True:
            scheduled = await jobs.get()
            if scheduled is None:
                jobs.task_done()
                break
            try:
                async with asyncio.timeout(options.timeout):
                    if writer is None:
                        reader, writer = await asyncio.open_connection(options.host, options.port)
                    writer.write(request)
                    await writer.drain()
                    head = await reader.readuntil(b"\r\n\r\n")
                    lines = head.split(b"\r\n")
                    status = int(lines[0].split(b" ")[1])
                    fields = {}
                    for line in lines[1:]:
                        if line:
                            key, value = line.split(b":", 1)
                            fields[key.lower()] = value.strip().lower()
                    if fields.get(b"transfer-encoding") == b"chunked":
                        while True:
                            size = int((await reader.readuntil(b"\r\n"))[:-2].split(b";", 1)[0], 16)
                            if size == 0:
                                while await reader.readuntil(b"\r\n") != b"\r\n":
                                    pass
                                break
                            await reader.readexactly(size)
                            if await reader.readexactly(2) != b"\r\n":
                                raise ValueError("invalid chunk boundary")
                    elif b"content-length" in fields:
                        await reader.readexactly(int(fields[b"content-length"]))
                    elif status not in (204, 304):
                        await reader.read()
                        fields[b"connection"] = b"close"
                    statuses[str(status)] += 1
                    outcome = "success" if 200 <= status < 400 else "rejected" if status in (429, 503) else "http_error"
                    latency[outcome].append(loop.time() - scheduled)
                    if fields.get(b"connection") == b"close":
                        writer.close()
                        try:
                            await writer.wait_closed()
                        except OSError:
                            pass
                        reader = writer = None
            except (OSError, EOFError, ValueError, asyncio.IncompleteReadError, asyncio.LimitOverrunError) as error:
                failures[type(error).__name__] += 1
                latency["transport_error"].append(loop.time() - scheduled)
                if writer is not None:
                    writer.close()
                    try:
                        await writer.wait_closed()
                    except OSError:
                        pass
                    reader = writer = None
            finally:
                jobs.task_done()
        if writer is not None:
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass

    workers = [asyncio.create_task(worker()) for _ in range(options.connections)]
    offered = math.ceil(options.rate * options.duration)
    started = loop.time()
    for number in range(offered):
        scheduled = started + number / options.rate
        delay = scheduled - loop.time()
        if delay > 0:
            await asyncio.sleep(delay)
        scheduler_lag.append(max(0, loop.time() - scheduled))
        try:
            jobs.put_nowait(scheduled)
        except asyncio.QueueFull:
            dropped += 1
    await jobs.join()
    elapsed = loop.time() - started
    for _ in workers:
        await jobs.put(None)
    await asyncio.gather(*workers)
    successes = len(latency["success"])
    return {
        "offered": offered,
        "offered_rate": options.rate,
        "offer_duration_seconds": options.duration,
        "elapsed_with_drain_seconds": elapsed,
        "statuses": dict(statuses),
        "transport_errors": dict(failures),
        "generator_queue_drops": dropped,
        "successes_per_second_with_drain": successes / elapsed,
        "scheduled_to_completion": {key: distribution(value) for key, value in latency.items()},
        "generator_scheduling_lag": distribution(scheduler_lag),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--path", default="/")
    parser.add_argument("--rate", type=float, default=1000)
    parser.add_argument("--duration", type=float, default=10)
    parser.add_argument("--connections", type=int, default=32)
    parser.add_argument("--queue", type=int, default=1024)
    parser.add_argument("--timeout", type=float, default=2)
    options = parser.parse_args()
    if not (0 < options.rate <= 1e6 and 0 < options.duration <= 3600 and
            options.rate * options.duration <= 1e6 and 0 < options.timeout <= 60 and
            1 <= options.connections <= 4096 and 1 <= options.queue <= 1e6):
        parser.error("positive bounded rate, duration, timeout, connections, and queue required; maximum one million offers")
    if not options.path.startswith("/") or any(c.isspace() for c in options.path + options.host):
        parser.error("path must be an origin-form target; host and path cannot contain whitespace")
    print(json.dumps(asyncio.run(run(options)), indent=2))


if __name__ == "__main__":
    main()
