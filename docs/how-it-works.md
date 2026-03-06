# Handing Off a Live TCP Socket from Elixir to Rust

How to use Unix `SCM_RIGHTS` to transfer an open TCP connection from the BEAM to a standalone Rust process — without the client noticing.

## The idea

Imagine an Elixir server that accepts a TCP connection, does some initial work, and then seamlessly hands the *open socket* to a Rust process that takes over for the rest of the session. The client sees a single unbroken TCP stream. No reconnection, no proxy layer, no copying bytes between processes — a true zero-copy handoff of the kernel socket itself.

This is useful when you want Elixir's supervision and orchestration strengths for connection setup, authentication, or routing, but need Rust's raw performance for the data-heavy phase that follows.

## What the demo looks like

```
$ just auto

  ← hello from elixir (1)      ← Elixir is talking
  ← hello from elixir (2)
  ...
  ← hello from elixir (10)     ← 2 seconds of greetings
  ← Hello from Rust             ← Rust has taken over the socket

  ← Rust echo: ping 1           ← Rust is now handling the connection
  ← Rust echo: ping 2
  ...
  [Rust] Client disconnected (EOF)
  [Rust] Exiting                 ← Rust exits when client closes
```

From the client's perspective this is one TCP connection. It never reconnects. Elixir opens the door, introduces itself, and then Rust steps in to handle the rest.

## How file descriptor passing works

Every open socket in a Unix process is just an integer — a *file descriptor* (FD). The kernel maintains a table mapping each FD to the underlying socket object. When two processes hold FDs that point to the same kernel socket, both can read from and write to that same TCP connection.

The trick is getting a copy of the FD into a different process. There are a few ways:

- **`fork()`** — child processes inherit parent FDs. But Rust processes aren't forked from the BEAM.
- **`pidfd_getfd()`** — Linux 5.6+ lets you copy an FD from another process. Requires `CAP_SYS_PTRACE` or same-user.
- **`SCM_RIGHTS`** — send an FD over a Unix domain socket as an ancillary message. The kernel allocates a new FD in the receiver that points to the same kernel socket. Works everywhere, no special privileges.

We use `SCM_RIGHTS` because it's portable, doesn't require special capabilities, and is the standard mechanism for this kind of work.

### The SCM_RIGHTS protocol

Two processes connect over a Unix domain socket (UDS). The sender calls `sendmsg()` with a `SCM_RIGHTS` control message containing the FD(s) to transfer. The receiver calls `recvmsg()` and the kernel delivers a fresh FD number in the receiver's FD table, pointing to the same underlying kernel socket object:

```
  Elixir (BEAM)                           Rust process
  ┌──────────────┐                        ┌──────────────┐
  │ FD 19 ───────┼──┐                     │              │
  │              │  │   UDS + SCM_RIGHTS   │              │
  │  sendmsg()  ─┼──┼────────────────────►─┤─ recvmsg()  │
  │              │  │                      │  FD 5 ──┐    │
  └──────────────┘  │                      └─────────┼────┘
                    │                                │
                    ▼                                ▼
              ┌──────────────────────────────────────────┐
              │  Kernel socket object (TCP connection)   │
              └──────────────────────────────────────────┘
```

After the transfer, both FD 19 (in the BEAM) and FD 5 (in Rust) refer to the same TCP connection. The BEAM stops using its copy; Rust takes over.

## Project structure

The project has three Rust compilation targets and a handful of Elixir modules:

```
hand_off_to_rust/
├── lib/
│   └── hand_off_to_rust/
│       ├── application.ex      # OTP application, starts the Listener
│       ├── listener.ex         # GenServer: accept, greet, handoff
│       └── fd_sender.ex        # Rustler NIF wrapper for send_fd
├── native/
│   └── fd_sender/              # Rustler NIF crate (cdylib)
│       └── src/lib.rs          # send_fd via SCM_RIGHTS
└── rust_handler/               # Standalone Rust binary
    └── src/main.rs             # Receives FD, greets, echoes, exits on EOF
```

Two of the Rust pieces use the [`nix`](https://crates.io/crates/nix) crate for the low-level socket operations. The NIF also uses [`rustler`](https://crates.io/crates/rustler) to bridge into the BEAM.

## Step by step

### 1. Elixir accepts and greets

The `Listener` GenServer opens a TCP listener and spawns an acceptor. When a client connects, it sends ten "hello from elixir" messages at 200ms intervals:

```elixir
# Send "hello from elixir" every 200ms for 2 seconds
count = div(@elixir_duration_ms, @elixir_interval_ms)

for i <- 1..count do
  :gen_tcp.send(client_socket, "hello from elixir (#{i})\n")
  Process.sleep(@elixir_interval_ms)
end
```

### 2. Extract the raw file descriptor

Erlang's `:gen_tcp` sockets are wrapped in port structures. The undocumented `:prim_inet.getfd/1` function extracts the raw OS file descriptor:

```elixir
{:ok, fd} = :prim_inet.getfd(client_socket)
```

This gives us the integer FD number (e.g. `19`) that we need to pass to Rust.

### 3. Spawn the Rust handler

The Listener starts the Rust binary as an Erlang Port, passing a unique UDS path as a command-line argument:

```elixir
uds_path = "/tmp/hand_off_#{System.pid()}_#{:erlang.unique_integer([:positive])}.sock"

port = Port.open({:spawn_executable, rust_binary}, [
  :binary, :exit_status, {:args, [uds_path]}, {:line, 1024}
])
```

Using `Port.open` gives us two things: stdout capture (so we can read the `READY` signal) and exit status notification (so we know when the Rust process terminates).

### 4. Rust signals readiness

The Rust binary binds a UDS listener on the given path and prints `READY` to stdout:

```rust
let listener = socket(AddressFamily::Unix, SockType::Stream, SockFlag::empty(), None)?;
bind(listener.as_raw_fd(), &UnixAddr::new(uds_path)?)?;
listen(&listener, Backlog::new(1).unwrap())?;

println!("READY");
std::io::stdout().flush().unwrap();
```

Back in Elixir, the GenServer waits for this signal:

```elixir
receive do
  {^port, {:data, {:eol, "READY"}}} ->
    :ok = HandOffToRust.FdSender.send_fd(uds_path, fd)
after
  5_000 -> Logger.error("Rust handler didn't signal READY in time")
end
```

### 5. The NIF sends the FD

The `FdSender` NIF connects to the Rust binary's UDS and sends the TCP socket's FD using `SCM_RIGHTS`:

```rust
#[rustler::nif(schedule = "DirtyIo")]
fn send_fd(path: String, fd: i32) -> NifResult<Atom> {
    let sock = socket(AddressFamily::Unix, SockType::Stream, SockFlag::empty(), None)?;
    connect(sock.as_raw_fd(), &UnixAddr::new(path.as_str())?)?;

    let data = [0u8; 1];
    let iov = [IoSlice::new(&data)];
    let fds = [fd];
    let cmsg = [ControlMessage::ScmRights(&fds)];

    sendmsg::<UnixAddr>(sock.as_raw_fd(), &iov, &cmsg, MsgFlags::empty(), None)?;
    Ok(atoms::ok())
}
```

The `schedule = "DirtyIo"` annotation tells the BEAM to run this NIF on a dirty I/O scheduler so it doesn't block the normal schedulers during the UDS connect/send.

### 6. Rust receives the FD and takes over

The Rust binary accepts the UDS connection and extracts the FD from the `SCM_RIGHTS` ancillary message:

```rust
let msg = recvmsg::<UnixAddr>(conn_fd, &mut iov, Some(&mut cmsg_buf), MsgFlags::empty())?;

let received_fd = msg.cmsgs()?.find_map(|cmsg| {
    if let ControlMessageOwned::ScmRights(fds) = cmsg {
        fds.into_iter().next()
    } else {
        None
    }
}).expect("no SCM_RIGHTS in message");
```

Then it reconstructs a `TcpStream` from the raw FD:

```rust
let mut stream = unsafe { TcpStream::from_raw_fd(received_fd) };
stream.set_nonblocking(false).expect("failed to set blocking mode");
```

The `set_nonblocking(false)` call is important — the BEAM keeps its sockets in non-blocking mode for its own I/O scheduler, and that mode is inherited through `SCM_RIGHTS`. Without switching to blocking mode, the first `read()` call in Rust would return `EAGAIN` immediately.

### 7. Elixir leaks the socket intentionally

After sending the FD, Elixir does *not* call `:gen_tcp.close/1`:

```elixir
# Don't close client_socket — gen_tcp.close sends TCP FIN which kills the
# connection. We intentionally leak the Erlang port; the Rust process now
# owns the connection via its SCM_RIGHTS-duplicated FD.
```

`:gen_tcp.close/1` calls `shutdown()` followed by `close()` on the underlying FD. The `shutdown()` sends a TCP FIN to the client, which would terminate the connection even though Rust still has its own copy of the FD. We avoid this by simply dropping the Elixir reference — the gen_tcp port is garbage collected eventually, and when `close()` happens without `shutdown()`, the kernel sees another FD (Rust's) still references the socket and keeps the connection alive.

## Gotchas

### Non-blocking inheritance

The BEAM runs all its sockets in non-blocking mode. When you pass an FD via `SCM_RIGHTS`, the new FD in the receiving process points to the same kernel socket object — including its non-blocking flag. Rust's `TcpStream::from_raw_fd()` doesn't change the mode. You must call `set_nonblocking(false)` before doing blocking reads.

### `CLOEXEC` prevents simple fork-and-exec

You might think: "why not just pass the FD number as a command-line argument and skip the UDS dance?" The BEAM sets `O_CLOEXEC` on its socket FDs. This flag tells the kernel to close the FD when `exec()` is called — which is exactly what happens when you spawn a child process via `Port.open`. By the time the Rust binary starts running, the FD is already closed.

`SCM_RIGHTS` sidesteps this entirely. The kernel creates a *new* FD in the receiving process, independent of `CLOEXEC` flags on the sender's copy.

### Don't call `gen_tcp.close/1` after handoff

As discussed above, `gen_tcp.close/1` sends a TCP FIN. If you need to clean up on the Elixir side, you can call `:erlang.port_close/1` on the underlying port, but even that calls `close()` on the FD. The safest approach is to simply stop referencing the socket and let the BEAM garbage collect it after the Rust process has finished.

### The 1-byte payload in `sendmsg`

The POSIX specification requires at least one byte of "real" data in a `sendmsg()` call, even when the only thing you care about is the ancillary `SCM_RIGHTS` message. Both the NIF and the Rust receiver include a dummy `[0u8; 1]` buffer for this purpose.

## Running the demo

```bash
# Build everything (NIF + standalone Rust binary + Elixir)
just build

# Terminal 1: start the server
just start

# Terminal 2: run the test client
just client

# Or run everything in one terminal
just auto

# Stop the server
just stop
```

## Why this matters

This pattern lets you combine Elixir's strengths — supervision trees, hot code loading, process isolation, distribution — with Rust's strengths — zero-cost abstractions, no GC pauses, predictable latency — on a *per-connection* basis. The BEAM handles the orchestration layer; Rust handles the data plane.

Possible applications:

- **Protocol upgrade**: Elixir handles TLS termination and authentication, then hands off the raw socket to a Rust media server for low-latency streaming.
- **Compute offload**: Elixir manages connection pools and backpressure, but delegates CPU-intensive protocol parsing to Rust.
- **Gradual migration**: Rewrite hot-path connection handlers in Rust one by one, while keeping Elixir for everything else.

The client never knows. It's the same TCP connection from start to finish.
