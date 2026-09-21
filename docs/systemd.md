# Running with systemd

[deploy/zhtps.service](../deploy/zhtps.service) runs the standalone server as a
dedicated, unprivileged `zhtps` user. Both listeners default to loopback: HTTP on
8080 and admin on 9090. The unit requires systemd 244 or later and the usual
[CPU and kernel requirements](getting-started.md).

## Install

Run these commands from the repository root on the destination host, using
Zig 0.16.0. Create the service account once; skip `useradd` if it already exists.

```sh
zig build -Doptimize=ReleaseSafe
sudo useradd --system --user-group --no-create-home --home-dir /nonexistent \
  --shell /usr/sbin/nologin zhtps
sudo install -o root -g root -m 0755 zig-out/bin/zhtps /usr/local/bin/zhtps
sudo install -d -o root -g root -m 0755 /etc/zhtps
sudo install -o root -g root -m 0644 deploy/zhtps.env /etc/zhtps/zhtps.env
sudo install -o root -g root -m 0644 deploy/zhtps.service /etc/systemd/system/zhtps.service
sudo systemd-analyze verify /etc/systemd/system/zhtps.service
sudo systemctl daemon-reload
sudo systemctl enable --now zhtps.service
```

Keep the bundled dependency notices with the installation when distributing the
binary; builds put them in `zig-out/share/licenses/zhtps/`.
On upgrades, preserve your edited `/etc/zhtps/zhtps.env`.

Check the service and its HTTP listeners:

```sh
systemctl status zhtps.service
sudo journalctl -u zhtps.service -f
curl --fail http://127.0.0.1:8080/
curl --fail http://127.0.0.1:9090/healthz
curl --fail http://127.0.0.1:9090/debug/config
```

`Type=exec` reports that the executable started; successful HTTP requests confirm
that initialization completed and the listeners are ready.

## Configure

Edit `/etc/zhtps/zhtps.env` to set `ZHTPS_ARGS` to the desired
[command-line options](../README.md#knobs), then run
`sudo systemctl restart zhtps.service`. The file uses systemd environment-file
syntax: no `export`, shell commands, or variable expansion. systemd splits
`$ZHTPS_ARGS` into arguments, respecting quoted words. For a path containing
spaces, use an outer single-quoted assignment and double-quote the path inside it.

To listen publicly, change the public address to `0.0.0.0` or a specific IP.
Keep `--admin-address 127.0.0.1`; admin has no authentication and remains HTTP.
When binding a specific address assigned during boot, add `Wants=network-online.target`
and `After=network-online.target` in a `[Unit]` drop-in and configure the network
manager's wait-online service.

For HTTPS on port 8443, install the PEM certificate chain and unencrypted key
outside home directories, readable by the service account:

```sh
sudo install -d -o root -g zhtps -m 0750 /etc/zhtps/tls
sudo install -o root -g zhtps -m 0640 /path/to/fullchain.pem /etc/zhtps/tls/fullchain.pem
sudo install -o root -g zhtps -m 0640 /path/to/privkey.pem /etc/zhtps/tls/privkey.pem
```

Set the environment file to:

```ini
ZHTPS_ARGS="--address 0.0.0.0 --port 8443 --admin-address 127.0.0.1 --admin-port 9090 --tls-certificate /etc/zhtps/tls/fullchain.pem --tls-key /etc/zhtps/tls/privkey.pem"
```

To use port 80 or 443, run `sudo systemctl edit zhtps.service` and add:

```ini
[Service]
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
```

Set the corresponding port in `ZHTPS_ARGS` and restart. TLS requires both
certificate flags regardless of port. Certificate renewal must update the installed
files and restart the service; zhtps has no reload signal or `ExecReload` command.

## Lifecycle and limits

Failures restart after five seconds, with at most five starts in a minute. Invalid
CLI options exit with status 2 and are not retried. After correcting a repeated
startup failure, use `sudo systemctl reset-failed zhtps.service` and start it again.
Stopping the unit sends SIGTERM for [graceful shutdown](runtime.md#graceful-shutdown-and-cancellation).
systemd allows 30 seconds before forcing termination. Keep `TimeoutStopSec` above
`--shutdown-timeout-ms`, with room for cancellation and cleanup.

The process descriptor limit is 65,536. Workers, connections, and memory use
zhtps's [automatic sizing](configuration.md#automatic-defaults), including cgroup
limits. Use `sudo systemctl edit zhtps.service` for deployment-specific resource
limits such as `MemoryHigh`, `MemoryMax`, `CPUQuota`, or `LimitNOFILE`, and restart
so zhtps discovers the new limits. `/debug/config` reports the resulting sizing.

The sandbox makes ordinary filesystem paths read-only, provides private temporary
storage, hides home directories, and drops capabilities by default. `/proc` and `/sys`
remain readable for resource discovery. It leaves the io_uring system calls
available; any additional syscall policy must allow `io_uring_setup`,
`io_uring_enter`, and `io_uring_register`. Hosts restricting io_uring to a group
must include the service user in that group; see [kernel configuration](../KERNEL_CONF.md#io_uring-availability-and-memory).
Embedded applications that write persistent files need an appropriate writable
directory, for example a systemd `StateDirectory`, and an application configuration
that uses it.
