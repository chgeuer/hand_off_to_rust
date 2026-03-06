defmodule HandOffToRust.MixProject do
  use Mix.Project

  def project do
    [
      app: :hand_off_to_rust,
      version: "0.1.0",
      elixir: "~> 1.20-rc",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {HandOffToRust.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.37.3"}
    ]
  end
end
