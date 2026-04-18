defmodule Espex.MixProject do
  use Mix.Project

  @app :espex
  @version "0.1.0"
  @source_url "https://github.com/bbangert/espex"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:thousand_island, "~> 1.4"},
      {:protobuf, "~> 0.12"},
      {:protobuf_generate, "~> 0.2", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      protobuf: [
        "protobuf.generate --output-path=./lib/espex/proto --include-path=./priv/protos --package-prefix=espex.proto priv/protos/api_options.proto priv/protos/api.proto"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_local_path: "priv/plts/project.plt",
      plt_core_path: "priv/plts/core.plt",
      flags: [:error_handling, :unknown, :extra_return, :missing_return]
    ]
  end

  defp description do
    "ESPHome Native API server library for Elixir."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv/protos .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Espex",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end
end
