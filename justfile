set shell := ["bash", "-euo", "pipefail", "-c"]

export PORT := `phx-port`
dev          := "scripts/dev_node.sh"

# List available tasks
default:
    @just --list

# Build the standalone Rust handler binary
build-rust:
    cargo build --release --manifest-path rust_handler/Cargo.toml
    mkdir -p priv
    cp rust_handler/target/release/rust_handler priv/rust_handler

# Fetch Elixir deps and compile (also builds the NIF via Rustler)
build-elixir:
    mix deps.get
    mix compile

# Build everything
build: build-rust build-elixir

# ──────────────────────────────────────────────
#  Node lifecycle
# ──────────────────────────────────────────────

# Start the BEAM node
start: build
    {{dev}} start

# Stop the background BEAM node
stop:
    {{dev}} stop

# Check if the node is running
status:
    {{dev}} status

# Tail the node log
log:
    {{dev}} log

# Run an expression on the live node
rpc *EXPR:
    {{dev}} rpc {{EXPR}}

# ──────────────────────────────────────────────
#  Demo workflow
# ──────────────────────────────────────────────

# Connect the Elixir test client (run in a second terminal)
client:
    PORT={{PORT}} elixir test_client.exs

# Connect with ncat — proves one raw TCP stream sees both servers
ncat:
    @echo "Connecting to localhost:{{PORT}} with ncat (type messages after handoff, Ctrl-C to quit)…"
    ncat localhost {{PORT}}

# Full automated demo (single terminal)
auto: build
    #!/usr/bin/env bash
    set -euo pipefail
    trap 'just stop 2>/dev/null; kill $(jobs -p) 2>/dev/null' EXIT

    just start
    sleep 1

    echo ""
    echo "📡 Starting test client — watch the handoff from Elixir → Rust …"
    echo ""
    just client

    just stop

# ──────────────────────────────────────────────
#  Observability
# ──────────────────────────────────────────────

# Show which OS processes own TCP sockets on this port (one-shot)
lsof:
    @echo "Socket owners on port {{PORT}}:"
    @echo "─────────────────────────────────────────────────────────────"
    @lsof -i TCP:{{PORT}} -n -P +c0 2>/dev/null || echo "(no sockets open)"

# Continuously watch socket ownership (refresh every 0.5s)
watch-sockets:
    watch -n 0.5 "lsof -i TCP:{{PORT}} -n -P +c0 2>/dev/null || echo '(no sockets open)'"

# ──────────────────────────────────────────────
#  Maintenance
# ──────────────────────────────────────────────

# Clean all build artifacts
clean:
    mix clean
    cargo clean --manifest-path rust_handler/Cargo.toml
    rm -f priv/rust_handler

# Show step-by-step instructions
demo:
    @echo ""
    @echo "╔══════════════════════════════════════════════════════════╗"
    @echo "║      Elixir → Rust TCP Socket Handoff Demo              ║"
    @echo "╚══════════════════════════════════════════════════════════╝"
    @echo ""
    @echo "  just start           Start server node (TCP on :${PORT})"
    @echo "  just client          Elixir test client   (new terminal)"
    @echo "  just ncat            Raw ncat client       (new terminal)"
    @echo "  just auto            Run full demo in one terminal"
    @echo ""
    @echo "  just lsof            Show socket owners on port :${PORT}"
    @echo "  just watch-sockets   Continuously watch socket ownership"
    @echo "  just log             Tail the server log"
    @echo "  just rpc '<e>'       Evaluate Elixir on the live node"
    @echo "  just stop            Stop the server"
    @echo ""
