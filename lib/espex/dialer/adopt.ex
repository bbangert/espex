defmodule Espex.Dialer.Adopt do
  @moduledoc false

  # Runs a socket espex dialed through Espex.Connection, the same handler
  # ThousandIsland runs accepted sockets through. ThousandIsland has no
  # API to adopt an outbound socket, so this uses the escape hatch its
  # Handler moduledoc documents ("When Handler Isn't Enough"): start the
  # handler, hand it the socket, then send it
  #
  #     {:thousand_island_ready, raw_socket, handler_config, acceptor_span, start_time}
  #
  # This module is the only one that knows that contract. The config is
  # built with HandlerConfig.from_server_config/1, not a struct literal,
  # so fields a release adds take their defaults (1.6.0 added
  # :handshake_timeout). The acceptor span is a struct literal: the
  # handler reads only its context and handler, and a literal emits no
  # acceptor telemetry for an acceptor that never ran. Dialed connections
  # therefore report a :connection span whose parent never started, and
  # they do not count against ThousandIsland's connection limits.
  # test/espex/outgoing_connection_test.exs guards the contract on every
  # thousand_island bump.

  alias ThousandIsland.{HandlerConfig, ServerConfig, Telemetry}

  @shutdown_ms 15_000

  @type opts :: [
          connection_supervisor: GenServer.server(),
          handler_options: keyword(),
          read_timeout: timeout()
        ]

  @doc """
  Open a TCP connection to `address:port`, passive and binary as
  ThousandIsland's TCP transport opens its sockets.
  """
  @spec connect(:inet.ip_address(), :inet.port_number(), timeout()) :: {:ok, :gen_tcp.socket()} | {:error, term()}
  def connect(address, port, timeout) do
    :gen_tcp.connect(address, port, [:binary, active: false, nodelay: true], timeout)
  end

  @doc """
  Run `socket` through a new `Espex.Connection` under the connection
  supervisor. Call it from the process that owns the socket. On an error
  the socket is closed.
  """
  @spec start_connection(:gen_tcp.socket(), opts()) :: {:ok, pid()} | {:error, term()}
  def start_connection(socket, opts) do
    supervisor = Keyword.fetch!(opts, :connection_supervisor)

    child =
      Supervisor.child_spec({Espex.Connection, {Keyword.fetch!(opts, :handler_options), []}}, shutdown: @shutdown_ms)

    with {:ok, pid} <- DynamicSupervisor.start_child(supervisor, child),
         :ok <- give_away(socket, supervisor, pid) do
      send(pid, {:thousand_island_ready, socket, handler_config(opts), acceptor_span(), System.monotonic_time()})
      {:ok, pid}
    else
      {:error, _reason} = error ->
        :gen_tcp.close(socket)
        error
    end
  end

  defp give_away(socket, supervisor, pid) do
    case :gen_tcp.controlling_process(socket, pid) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        _ = DynamicSupervisor.terminate_child(supervisor, pid)
        error
    end
  end

  defp handler_config(opts) do
    [
      handler_module: Espex.Connection,
      transport_module: ThousandIsland.Transports.TCP,
      read_timeout: Keyword.fetch!(opts, :read_timeout)
    ]
    |> ServerConfig.new()
    |> HandlerConfig.from_server_config()
  end

  defp acceptor_span do
    context = make_ref()
    metadata = %{telemetry_span_context: context, handler: Espex.Connection}

    %Telemetry{
      span_name: :acceptor,
      telemetry_span_context: context,
      start_time: System.monotonic_time(),
      start_metadata: metadata,
      handler: Espex.Connection,
      span_metadata: metadata
    }
  end
end
