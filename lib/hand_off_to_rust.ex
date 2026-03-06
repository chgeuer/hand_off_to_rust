defmodule HandOffToRust do
  @moduledoc """
  Demonstrates handing off an open TCP socket from an Elixir process
  to a standalone Rust process using SCM_RIGHTS (Unix domain socket
  file descriptor passing).

  ## How it works

  1. Elixir listens on a TCP port, accepts a connection, sends "HELLO from Elixir"
  2. Elixir spawns a Rust binary, passing a UDS path as argument
  3. The Rust binary binds to the UDS and signals READY via stdout
  4. Elixir sends the TCP socket's file descriptor over UDS via SCM_RIGHTS (NIF)
  5. The Rust process receives the FD, sends "Hello from Rust", and echoes data
  6. When the client disconnects, the Rust process exits
  """
end
