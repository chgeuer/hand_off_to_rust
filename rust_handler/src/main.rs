use nix::sys::socket::{
    accept, bind, listen, recvmsg, socket, AddressFamily, Backlog, ControlMessageOwned, MsgFlags,
    SockFlag, SockType, UnixAddr,
};
use nix::unistd::close;
use std::env;
use std::io::{IoSliceMut, Read, Write};
use std::net::TcpStream;
use std::os::fd::AsRawFd;
use std::os::unix::io::FromRawFd;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 2 {
        eprintln!("Usage: {} <uds_path>", args[0]);
        std::process::exit(1);
    }
    let uds_path = &args[1];

    // Receive the TCP socket FD from Elixir via SCM_RIGHTS over UDS
    let fd = receive_fd(uds_path);
    eprintln!("[Rust] Received TCP socket FD {fd}");

    // Reconstruct a TcpStream from the raw file descriptor
    let mut stream = unsafe { TcpStream::from_raw_fd(fd) };

    // The socket is non-blocking (inherited from the BEAM), switch to blocking
    stream
        .set_nonblocking(false)
        .expect("failed to set blocking mode");

    // Send the Rust greeting
    if let Err(e) = stream.write_all(b"Hello from Rust\n") {
        eprintln!("[Rust] Failed to send greeting: {e}");
        std::process::exit(1);
    }

    // Echo loop: read data from the client until disconnect
    let mut buf = [0u8; 1024];
    loop {
        match stream.read(&mut buf) {
            Ok(0) => {
                eprintln!("[Rust] Client disconnected (EOF)");
                break;
            }
            Ok(n) => {
                let data = String::from_utf8_lossy(&buf[..n]);
                eprintln!("[Rust] Received: {}", data.trim());
                let reply = format!("Rust echo: {}", data);
                if stream.write_all(reply.as_bytes()).is_err() {
                    eprintln!("[Rust] Write error, client likely disconnected");
                    break;
                }
            }
            Err(e) => {
                eprintln!("[Rust] Read error: {e}");
                break;
            }
        }
    }

    eprintln!("[Rust] Exiting");
}

/// Bind a UDS, signal READY to the parent (Elixir), accept one connection,
/// and receive a file descriptor via SCM_RIGHTS.
fn receive_fd(uds_path: &str) -> i32 {
    // Remove stale socket file
    let _ = std::fs::remove_file(uds_path);

    let listener = socket(
        AddressFamily::Unix,
        SockType::Stream,
        SockFlag::empty(),
        None,
    )
    .expect("socket()");

    let addr = UnixAddr::new(uds_path).expect("UnixAddr");
    bind(listener.as_raw_fd(), &addr).expect("bind()");
    listen(&listener, Backlog::new(1).unwrap()).expect("listen()");

    // Signal readiness to the parent Elixir process via stdout
    println!("READY");
    std::io::stdout().flush().unwrap();

    // Accept one connection from Elixir's NIF
    let conn_fd = accept(listener.as_raw_fd()).expect("accept()");

    // Receive the FD via SCM_RIGHTS ancillary message
    let mut buf = [0u8; 1];
    let mut iov = [IoSliceMut::new(&mut buf)];
    let mut cmsg_buf = nix::cmsg_space!(std::os::unix::io::RawFd);

    let msg = recvmsg::<UnixAddr>(conn_fd, &mut iov, Some(&mut cmsg_buf), MsgFlags::empty())
        .expect("recvmsg()");

    let received_fd = msg
        .cmsgs()
        .expect("failed to parse cmsgs")
        .find_map(|cmsg| {
            if let ControlMessageOwned::ScmRights(fds) = cmsg {
                fds.into_iter().next()
            } else {
                None
            }
        })
        .expect("no SCM_RIGHTS in message");

    // Cleanup UDS
    let _ = close(conn_fd);
    drop(listener);
    let _ = std::fs::remove_file(uds_path);

    received_fd
}
