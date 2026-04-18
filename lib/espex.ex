defmodule Espex do
  @moduledoc """
  ESPHome Native API server library.

  Start under your own supervision tree:

      children = [
        {Espex,
         device_config: [name: "my-device", friendly_name: "My Device"],
         serial_proxy: MyApp.MySerialAdapter,
         zwave_proxy: MyApp.MyZWaveAdapter,
         infrared_proxy: MyApp.MyInfraredAdapter,
         entity_provider: MyApp.MyEntities}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  Any adapter key omitted → that feature is disabled. See
  `Espex.Supervisor` for the full list of start options.

  ## Implementing adapters

  Four behaviours define the consumer contract for hardware:

    * `Espex.SerialProxy` — one or more serial ports exposed over the
      Native API's serial proxy feature
    * `Espex.ZWaveProxy` — a Z-Wave Serial API controller proxied to
      clients (typically Home Assistant)
    * `Espex.InfraredProxy` — IR transmit/receive devices
    * `Espex.EntityProvider` — arbitrary ESPHome entities (sensors,
      switches, etc.)
  """

  alias Espex.{DeviceConfig, Server}

  @doc """
  `child_spec/1` — makes `{Espex, opts}` usable as a child spec.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: opts[:name] || __MODULE__,
      start: {Espex.Supervisor, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @doc """
  Start the full Espex supervision tree with the given options.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(opts), to: Espex.Supervisor

  @doc """
  Return the running server's `%DeviceConfig{}`. Accepts an optional
  server name for non-default supervisor setups.
  """
  @spec device_config(GenServer.server()) :: DeviceConfig.t()
  def device_config(server \\ Server), do: Server.device_config(server)
end
