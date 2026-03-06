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

    // 1-byte data payload (required by sendmsg)
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

rustler::init!("Elixir.HandOffToRust.FdSender");
