defmodule HandOffToRust.Listener do
  @moduledoc """
  GenServer that listens for TCP connections, sends "hello from elixir"
  every 200ms for 2 seconds, then hands off each accepted socket to a
  dedicated Rust process via SCM_RIGHTS file descriptor passing.
  """
  use GenServer
  require Logger

  @default_port 4000
  @elixir_interval_ms 200
  @elixir_duration_ms 2_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    port = port_from_env()
    {:ok, lsock} = :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])
    Logger.info("[Listener] Listening on TCP port #{port}")
    send(self(), :accept)
    {:ok, %{listen_socket: lsock}}
  end

  @impl true
  def handle_info(:accept, state) do
    me = self()

    spawn_link(fn ->
      case :gen_tcp.accept(state.listen_socket) do
        {:ok, client} ->
          :gen_tcp.controlling_process(client, me)
          send(me, {:new_client, client})

        {:error, :closed} ->
          :ok

        {:error, reason} ->
          Logger.error("[Listener] Accept error: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  def handle_info({:new_client, client_socket}, state) do
    Logger.info("[Listener] New client connected")

    # Send "hello from elixir" every 200ms for 2 seconds
    count = div(@elixir_duration_ms, @elixir_interval_ms)

    for i <- 1..count do
      :gen_tcp.send(client_socket, "hello from elixir (#{i})\n")
      Process.sleep(@elixir_interval_ms)
    end

    Logger.info("[Listener] Elixir greeting phase done, handing off to Rust")

    # Extract the raw OS file descriptor
    {:ok, fd} = :prim_inet.getfd(client_socket)
    Logger.info("[Listener] Extracted FD #{fd}")

    # Start the Rust handler binary with a unique UDS path
    uds_path = "/tmp/hand_off_#{System.pid()}_#{:erlang.unique_integer([:positive])}.sock"
    rust_binary = rust_handler_path()

    port =
      Port.open({:spawn_executable, rust_binary}, [
        :binary,
        :exit_status,
        {:args, [uds_path]},
        {:line, 1024}
      ])

    # Wait for the Rust process to signal readiness
    receive do
      {^port, {:data, {:eol, "READY"}}} ->
        Logger.info("[Listener] Rust handler ready, sending FD #{fd}")

        # Send the TCP socket FD over UDS using SCM_RIGHTS
        :ok = HandOffToRust.FdSender.send_fd(uds_path, fd)
        Logger.info("[Listener] FD #{fd} handed off to Rust handler")
    after
      5_000 ->
        Logger.error("[Listener] Rust handler didn't signal READY in time")
        Port.close(port)
    end

    # Don't close client_socket — gen_tcp.close sends TCP FIN which kills the
    # connection. We intentionally leak the Erlang port; the Rust process now
    # owns the connection via its SCM_RIGHTS-duplicated FD.

    # Accept next client
    send(self(), :accept)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    Logger.info("[Listener] Rust handler exited with status #{status}")
    {:noreply, state}
  end

  def handle_info({port, {:data, {:eol, line}}}, state) when is_port(port) do
    Logger.info("[Rust] #{line}")
    {:noreply, state}
  end

  defp rust_handler_path do
    candidates = [
      Path.join(to_string(:code.priv_dir(:hand_off_to_rust)), "rust_handler"),
      Path.join([File.cwd!(), "rust_handler", "target", "release", "rust_handler"]),
      Path.join([File.cwd!(), "rust_handler", "target", "debug", "rust_handler"])
    ]

    Enum.find(candidates, &File.exists?/1) ||
      raise """
      Rust handler binary not found! Build it first:

          cargo build --release --manifest-path rust_handler/Cargo.toml
          cp rust_handler/target/release/rust_handler priv/
      """
  end

  defp port_from_env do
    case System.get_env("PORT") do
      nil -> @default_port
      val -> String.to_integer(val)
    end
  end
end
