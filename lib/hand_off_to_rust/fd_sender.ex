defmodule HandOffToRust.FdSender do
  @moduledoc """
  NIF wrapper for sending a file descriptor over a Unix Domain Socket
  using SCM_RIGHTS ancillary messages.
  """
  use Rustler, otp_app: :hand_off_to_rust, crate: "fd_sender"

  @doc "Send a file descriptor over UDS at `path` using SCM_RIGHTS."
  @spec send_fd(String.t(), integer()) :: :ok | no_return()
  def send_fd(_path, _fd), do: :erlang.nif_error(:nif_not_loaded)
end
