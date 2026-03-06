#!/usr/bin/env elixir
# Test client for the HandOffToRust demo.
# Connects to the server, reads the Elixir greetings and Rust greeting,
# sends a few messages to the Rust echo handler, then disconnects.

defmodule TestClient do
  @default_port 4000

  def run do
    port = port_from_env()
    IO.puts("[Client] Connecting to localhost:#{port}...")

    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :line]) do
      {:ok, sock} ->
        IO.puts("[Client] Connected!\n")

        # Read all Elixir greetings + Rust greeting (keep reading until we get the Rust one)
        read_greetings(sock)

        # Send a few messages to Rust and read echoes
        for i <- 1..5 do
          msg = "ping #{i}\n"
          :gen_tcp.send(sock, msg)

          case :gen_tcp.recv(sock, 0, to_timeout(second: 5)) do
            {:ok, data} -> IO.puts("  ← #{String.trim(data)}")
            {:error, reason} -> IO.puts("  ✗ Recv error: #{inspect(reason)}")
          end

          Process.sleep(300)
        end

        IO.puts("\n[Client] Closing connection...")
        :gen_tcp.close(sock)
        IO.puts("[Client] Done.")

      {:error, reason} ->
        IO.puts("[Client] Connection failed: #{inspect(reason)}")
    end
  end

  defp read_greetings(sock) do
    case :gen_tcp.recv(sock, 0, to_timeout(second: 5)) do
      {:ok, data} ->
        line = String.trim(data)
        IO.puts("  ← #{line}")

        if String.starts_with?(line, "Hello from Rust") do
          IO.puts("")
          :ok
        else
          read_greetings(sock)
        end

      {:error, reason} ->
        IO.puts("  ✗ Recv error during greetings: #{inspect(reason)}")
    end
  end

  defp port_from_env do
    case System.get_env("PORT") do
      nil -> @default_port
      val -> String.to_integer(val)
    end
  end
end

TestClient.run()
