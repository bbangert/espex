defmodule Espex.Mdns.Advertiser do
  @moduledoc """
  GenServer that owns one mDNS service advertisement for an
  `Espex.Supervisor` instance.

  Started as the last child of the supervisor's `:rest_for_one` chain,
  so by the time `handle_continue/2` runs, `ThousandIsland` has already
  bound and `Espex.Supervisor.bound_port/1` resolves the ephemeral port
  (if `port: 0` was requested). The advertisement comes down on
  supervisor shutdown via `terminate/2`.
  """

  use GenServer

  require Logger

  alias Espex.DeviceConfig

  @type opts :: [
          adapter: module(),
          device_config: DeviceConfig.t(),
          supervisor_name: atom(),
          port: :inet.port_number() | nil,
          name: GenServer.name()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    # Trap exits so terminate/2 runs on supervisor shutdown — without
    # this, the parent's exit signal kills us before withdraw fires.
    Process.flag(:trap_exit, true)

    state = %{
      adapter: Keyword.fetch!(opts, :adapter),
      device_config: Keyword.fetch!(opts, :device_config),
      supervisor_name: Keyword.fetch!(opts, :supervisor_name),
      port_override: Keyword.get(opts, :port),
      service_id: nil
    }

    # Defer the work out of init so Supervisor.which_children/1 (used by
    # bound_port/1) doesn't deadlock with the supervisor that's still in
    # the middle of starting us.
    {:ok, state, {:continue, :advertise}}
  end

  @impl GenServer
  # mDNS is best-effort discovery — if the adapter or port lookup fails we
  # log and stay up so the API listener still serves clients that find us
  # by other means (static IP, prior cache).
  def handle_continue(:advertise, state) do
    case resolve_port(state) do
      {:ok, port} ->
        service =
          state.device_config
          |> DeviceConfig.to_mdns_service()
          |> Map.put(:port, port)

        case state.adapter.advertise(service) do
          :ok ->
            Logger.info("Espex.Mdns advertised #{service.protocol}.#{service.transport} on port #{port}")
            {:noreply, %{state | service_id: service.id}}

          {:error, reason} ->
            Logger.warning("Espex.Mdns adapter advertise failed: #{inspect(reason)}")
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.warning("Espex.Mdns port resolution failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, %{service_id: nil}), do: :ok
  def terminate(_reason, %{adapter: adapter, service_id: id}), do: adapter.withdraw(id)

  defp resolve_port(%{port_override: port}) when is_integer(port) and port > 0, do: {:ok, port}

  defp resolve_port(%{supervisor_name: sup}) do
    Espex.Supervisor.bound_port(sup)
  end
end
