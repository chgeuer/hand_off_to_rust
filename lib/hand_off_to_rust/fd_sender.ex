defmodule HandOffToRust.FdSender do
  @moduledoc """
  NIF wrapper for file descriptor operations over Unix Domain Sockets
  using SCM_RIGHTS ancillary messages.
  """
  use Rustler, otp_app: :hand_off_to_rust, crate: "fd_sender"

  @doc "Send a file descriptor over UDS at `path` using SCM_RIGHTS."
  @spec send_fd(String.t(), non_neg_integer()) :: :ok
  def send_fd(_path, _fd), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Release the BEAM's reference to a socket FD after handoff.

  Uses dup2() to replace the FD with /dev/null, decrementing the kernel
  socket's refcount without calling shutdown() (which would send TCP FIN).
  The Erlang port driver keeps a valid FD so GC doesn't close a reused number.
  """
  @spec release_fd(non_neg_integer()) :: :ok
  def release_fd(_fd), do: :erlang.nif_error(:nif_not_loaded)
end
