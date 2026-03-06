defmodule HandOffToRust.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      HandOffToRust.Listener
    ]

    opts = [strategy: :one_for_one, name: HandOffToRust.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
