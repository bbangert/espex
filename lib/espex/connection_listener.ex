defmodule Espex.ConnectionListener do
  @moduledoc """
  Behaviour for being notified when the set of connected native-API
  clients changes.

  Espex stays framework-agnostic — it has no `Phoenix.PubSub` dependency.
  Instead, configure a `:connection_listener` module (like the other
  adapters) and Espex calls `c:connections_changed/0` once when a client
  finishes connecting (sends its `HelloRequest`) and once when a client
  disconnects. Per-frame activity updates do **not** trigger it.

  The callback carries no payload by design: it is a lightweight "the set
  changed, go look" signal. On receipt, call `Espex.connected_clients/1`
  to read the current set.

  ## The callback is best-effort — reconcile on boot

  `connections_changed/0` is fire-and-forget. Espex invokes it in a
  detached process and catches every failure kind, so a slow, blocking,
  or crashing listener can never stall or drop a live client connection;
  it does **not** retry or buffer, and notifications are **unordered**. A
  client can connect the instant the TCP listener is up — possibly before
  your listener process is ready — so a notification can be missed during
  startup.

  Because `Espex.connected_clients/1` always reflects the live Registry,
  the robust pattern is **treat the callback as a hint and the query as
  the truth**: read `connected_clients/1` once when your listener starts,
  then again on every `connections_changed/0`. That reconciles any
  notification missed before you were ready.

  Start your listener **before** the Espex child (and use `:rest_for_one`)
  so it is ready as early as possible:

      children = [
        {MyApp.ClientTracker, []},
        {Espex,
         server_name: MyApp.EspexServer,
         device_config: [name: "my-device"],
         connection_listener: MyApp.ClientTracker}
      ]

      Supervisor.start_link(children, strategy: :rest_for_one)

  ## Example

      defmodule MyApp.ClientTracker do
        @behaviour Espex.ConnectionListener
        use GenServer

        def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

        # --- ConnectionListener callback ---

        @impl Espex.ConnectionListener
        def connections_changed do
          # Cast (never block the connection process) and reconcile from
          # the source of truth.
          GenServer.cast(__MODULE__, :refresh)
        end

        # --- GenServer ---

        @impl GenServer
        def init(_) do
          # Reconcile on boot — catches any client that connected before
          # this process was ready.
          {:ok, %{clients: Espex.connected_clients(MyApp.EspexServer)}}
        end

        @impl GenServer
        def handle_cast(:refresh, state) do
          clients = Espex.connected_clients(MyApp.EspexServer)
          Phoenix.PubSub.broadcast(MyApp.PubSub, "espex:clients", {:clients, clients})
          {:noreply, %{state | clients: clients}}
        end
      end
  """

  @doc """
  Invoked once when a client completes its hello (connect) and once when
  a client disconnects. Return value is ignored.

  Keep it fast and non-raising — cast to your own process and read
  `Espex.connected_clients/1` there.
  """
  @callback connections_changed() :: any()
end
