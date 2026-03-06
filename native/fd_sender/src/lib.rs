use nix::sys::socket::{
    connect, sendmsg, socket, AddressFamily, ControlMessage, MsgFlags, SockFlag, SockType,
    UnixAddr,
};
use rustler::{Atom, Error, NifResult};
use std::io::IoSlice;
use std::os::fd::AsRawFd;

mod atoms {
    rustler::atoms! {
        ok,
    }
}

/// Send a file descriptor over a Unix Domain Socket using SCM_RIGHTS.
///
/// Connects to the UDS at `path`, sends `fd` as ancillary data, then closes
/// the UDS connection. The sent FD remains valid in the calling process.
#[rustler::nif(schedule = "DirtyIo")]
fn send_fd(path: String, fd: i32) -> NifResult<Atom> {
    let sock = socket(
        AddressFamily::Unix,
        SockType::Stream,
        SockFlag::empty(),
        None,
    )
    .map_err(|e| Error::Term(Box::new(format!("socket(): {e}"))))?;

    let addr = UnixAddr::new(path.as_str())
        .map_err(|e| Error::Term(Box::new(format!("UnixAddr: {e}"))))?;

    connect(sock.as_raw_fd(), &addr)
        .map_err(|e| Error::Term(Box::new(format!("connect(): {e}"))))?;

    // SCM_RIGHTS requires at least 1 byte of "real" data in the message
    let data = [0u8; 1];
    let iov = [IoSlice::new(&data)];

    // SCM_RIGHTS ancillary message carrying the target FD
    let fds = [fd];
    let cmsg = [ControlMessage::ScmRights(&fds)];

    sendmsg::<UnixAddr>(sock.as_raw_fd(), &iov, &cmsg, MsgFlags::empty(), None)
        .map_err(|e| Error::Term(Box::new(format!("sendmsg(): {e}"))))?;

    drop(sock);
    Ok(atoms::ok())
}

/// Release the BEAM's reference to a socket FD after handoff.
///
/// Uses dup2() to atomically replace the FD with /dev/null. This:
/// 1. Decrements the kernel socket's refcount (so it can fully close when
///    the Rust process is done)
/// 2. Leaves the Erlang port driver with a valid FD (pointing to /dev/null)
///    so it won't accidentally close a reused FD number during GC
///
/// We can't use gen_tcp.close/1 because it calls shutdown() which sends a
/// TCP FIN and kills the connection for all FD holders.
///
/// # Safety concern
///
/// Calling this with a wrong FD (e.g., the BEAM's epoll FD or a scheduler
/// pipe) would silently replace it with /dev/null, corrupting the VM.
/// We validate that the FD points to a socket before proceeding.
#[rustler::nif]
fn release_fd(fd: i32) -> NifResult<Atom> {
    use std::os::fd::IntoRawFd;

    if fd < 0 {
        return Err(Error::Term(Box::new(format!("invalid FD: {fd}"))));
    }

    // Verify this FD is actually a socket before we dup2 over it.
    // This prevents accidentally destroying BEAM-internal FDs (epoll,
    // scheduler pipes, file handles) if the caller passes a wrong number.
    //
    // SAFETY: We're probing the FD type, not taking ownership. The FD remains
    // valid and owned by the BEAM's port/socket driver throughout.
    let borrowed = unsafe { std::os::fd::BorrowedFd::borrow_raw(fd) };
    match nix::sys::socket::getsockopt(&borrowed, nix::sys::socket::sockopt::SockType) {
        Ok(_) => {} // It's a socket — safe to proceed
        Err(_) => {
            return Err(Error::Term(Box::new(format!(
                "FD {fd} is not a socket — refusing to release (would corrupt the VM)"
            ))));
        }
    }

    let devnull = std::fs::File::open("/dev/null")
        .map_err(|e| Error::Term(Box::new(format!("open /dev/null: {e}"))))?;
    let devnull_fd = devnull.into_raw_fd();

    nix::unistd::dup2(devnull_fd, fd)
        .map_err(|e| Error::Term(Box::new(format!("dup2(): {e}"))))?;

    nix::unistd::close(devnull_fd)
        .map_err(|e| Error::Term(Box::new(format!("close(): {e}"))))?;

    Ok(atoms::ok())
}

rustler::init!("Elixir.HandOffToRust.FdSender");
