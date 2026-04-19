defmodule Espex.MixProject do
  use Mix.Project

  @app :espex
  @version "0.1.1"
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
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Exercised by the mDNS integration test and the mdns_demo manual
      # script. Not a runtime dep — Espex.Mdns.MdnsLite uses late-binding
      # so espex loads without it for downstream apps that don't need
      # mDNS.
      {:mdns_lite, "~> 0.8", only: [:dev, :test]}
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
      files: ~w(lib guides priv/protos .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: [
        "README.md",
        "guides/architecture.md",
        "guides/entity_types.md"
      ],
      groups_for_extras: [
        Guides: ~r"guides/.*"
      ]
    ]
  end
end
