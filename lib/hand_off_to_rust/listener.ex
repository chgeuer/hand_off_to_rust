defmodule HandOffToRust.Listener do
  @moduledoc """
  GenServer that listens for TCP connections, sends "hello from elixir"
  every 200ms for 2 seconds, then hands off each accepted socket to a
  dedicated Rust process via SCM_RIGHTS file descriptor passing.
  """
  use GenServer
  require Logger

  @default_port 4000
  @elixir_interval_ms to_timeout(millisecond: 200)
  @elixir_duration_ms to_timeout(second: 2)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    port = port_from_env()
    {:ok, lsock} = :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])
    Logger.info("[Listener] Listening on TCP port #{port}")
    send(self(), :accept)
    {:ok, %{listen_socket: lsock, tcp_port: port}}
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

    # Show who owns the socket BEFORE handoff
    log_socket_owners("BEFORE handoff", state.tcp_port, fd)

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

        # Release the BEAM's reference to the socket FD.
        # dup2() replaces FD with /dev/null — decrements the kernel socket's
        # refcount without calling shutdown() (which would send TCP FIN).
        :ok = HandOffToRust.FdSender.release_fd(fd)
        Logger.info("[Listener] Released BEAM's FD #{fd} (dup2'd to /dev/null)")

        # Brief pause so Rust has time to receive the FD before we probe
        Process.sleep(100)

        # Show who owns the socket AFTER handoff
        log_socket_owners("AFTER handoff", state.tcp_port, fd)
    after
      5_000 ->
        Logger.error("[Listener] Rust handler didn't signal READY in time")
        Port.close(port)
    end

    # The gen_tcp port still exists but its FD now points to /dev/null.
    # When Erlang GCs the port, closing /dev/null is harmless.

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

  # Show which OS processes hold a file descriptor to the TCP connection.
  # Reads /proc/self/fd to show the socket inode on the BEAM side, and
  # runs lsof to list all processes with ESTABLISHED connections on the port.
  defp log_socket_owners(label, tcp_port, fd) do
    beam_pid = System.pid()

    # Show what the BEAM's FD points to (e.g. socket:[1234567])
    fd_link =
      case File.read_link("/proc/#{beam_pid}/fd/#{fd}") do
        {:ok, target} -> target
        {:error, _} -> "?"
      end

    Logger.info("[#{label}] BEAM pid=#{beam_pid}, FD #{fd} → #{fd_link}")

    # Run lsof to show all processes with ESTABLISHED connections on this port
    case System.cmd("lsof", ["-i", "TCP:#{tcp_port}", "-n", "-P", "+c0"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        lines =
          output
          |> String.split("\n")
          |> Enum.filter(&String.contains?(&1, "ESTABLISHED"))

        if lines != [] do
          Logger.info("[#{label}] Socket owners (lsof):")

          for line <- lines do
            Logger.info("  #{line}")
          end
        end

      _ ->
        :ok
    end
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
