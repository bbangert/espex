defmodule Espex.Server do
  @moduledoc """
  GenServer holding the `%Espex.ServerState{}` for the running server.

  Thin wrapper over `Espex.ServerState` — each `handle_*` unwraps the
  state, calls a pure function on `ServerState`, and returns. Per-connection
  snapshot work happens in `Espex.Connection` at accept time rather than
  here, so this server holds only the stable cross-connection facts.
  """

  use GenServer

  alias Espex.{ConnectionState, DeviceConfig, ServerState}

  @type start_opts :: [
          name: GenServer.name(),
          device_config: DeviceConfig.t() | keyword(),
          adapters: map()
        ]

  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Return a snapshot of the current `%ServerState{}`.
  """
  @spec get_state(GenServer.server()) :: ServerState.t()
  def get_state(server \\ __MODULE__), do: GenServer.call(server, :get_state)

  @doc """
  Return the configured `%DeviceConfig{}`.
  """
  @spec device_config(GenServer.server()) :: DeviceConfig.t()
  def device_config(server \\ __MODULE__), do: GenServer.call(server, :device_config)

  @doc """
  Return the full adapter registry.
  """
  @spec adapters(GenServer.server()) :: ConnectionState.adapters()
  def adapters(server \\ __MODULE__), do: GenServer.call(server, :adapters)

  @impl GenServer
  def init(opts) do
    device_config = normalise_device_config(opts[:device_config])
    adapters = opts[:adapters] || %{}

    state =
      ServerState.new(device_config: device_config)
      |> ServerState.put_adapters(Map.new(adapters))

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state), do: {:reply, state, state}
  def handle_call(:device_config, _from, state), do: {:reply, state.device_config, state}
  def handle_call(:adapters, _from, state), do: {:reply, state.adapters, state}

  defp normalise_device_config(%DeviceConfig{} = config), do: config
  defp normalise_device_config(opts) when is_list(opts), do: DeviceConfig.new(opts)
  defp normalise_device_config(nil), do: DeviceConfig.new()
end
