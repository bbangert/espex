defmodule Espex.SerialProxy do
  @moduledoc """
  Behaviour for serial proxy adapters.

  Implement this to expose one or more serial ports to ESPHome clients
  through the Native API's serial proxy feature. Espex calls these
  callbacks from connection handler processes; it does not own port
  state directly.

  Data arriving on an opened port is delivered to the `subscriber` pid
  passed to `c:open/3` as:

      {:espex_serial_data, handle, binary}

  where `handle` is the opaque term the adapter returned from `c:open/3`.

  ## Example

      defmodule MyApp.MySerialAdapter do
        @behaviour Espex.SerialProxy

        @impl Espex.SerialProxy
        def list_instances do
          [Espex.SerialProxy.Info.new(instance: 0, name: "zigbee", port_type: :ttl)]
        end

        @impl Espex.SerialProxy
        def open(0, _opts, subscriber), do: {:ok, start_pump(subscriber)}
        # ...
      end
  """

  alias Espex.Proto
  alias Espex.SerialProxy.Info

  @typedoc "Opaque handle returned by the adapter from `c:open/3`."
  @type handle :: term()

  @typedoc """
  Options for opening a serial port. Keys follow the fields on
  `SerialProxyConfigureRequest` but normalised to atoms.
  """
  @type open_opts :: [
          speed: non_neg_integer(),
          data_bits: 5..8,
          stop_bits: 1..2,
          parity: :none | :even | :odd,
          flow_control: :none | :hardware
        ]

  @doc """
  Translate a `SerialProxyConfigureRequest` protobuf into the keyword
  list passed to `c:open/3`. Zero-valued protobuf fields fall back to
  sensible defaults (9600-8-N-1, no flow control).
  """
  @spec configure_request_to_open_opts(Proto.SerialProxyConfigureRequest.t()) :: open_opts()
  def configure_request_to_open_opts(%Proto.SerialProxyConfigureRequest{} = req) do
    [
      speed: if(req.baudrate > 0, do: req.baudrate, else: 9600),
      data_bits: if(req.data_size > 0, do: req.data_size, else: 8),
      stop_bits: if(req.stop_bits > 0, do: req.stop_bits, else: 1),
      parity: parity_atom(req.parity),
      flow_control: if(req.flow_control, do: :hardware, else: :none)
    ]
  end

  defp parity_atom(:SERIAL_PROXY_PARITY_EVEN), do: :even
  defp parity_atom(:SERIAL_PROXY_PARITY_ODD), do: :odd
  defp parity_atom(_), do: :none

  @doc """
  Return the list of available serial proxy instances.
  """
  @callback list_instances() :: [Info.t()]

  @doc """
  Open the given instance with the supplied options. Data received on the
  port must be forwarded to `subscriber` as `{:espex_serial_data, handle,
  binary}`.
  """
  @callback open(instance :: non_neg_integer(), open_opts(), subscriber :: pid()) ::
              {:ok, handle()} | {:error, term()}

  @doc """
  Write bytes to an opened instance.
  """
  @callback write(handle(), data :: binary()) :: :ok | {:error, term()}

  @doc """
  Close an opened instance and release any associated resources.
  """
  @callback close(handle()) :: :ok

  @doc """
  Set the RTS and DTR modem control lines. Optional — return
  `{:error, :not_supported}` if the adapter doesn't support modem
  pin control.
  """
  @callback set_modem_pins(handle(), rts :: boolean(), dtr :: boolean()) ::
              :ok | {:error, term()}

  @doc """
  Read the current state of the RTS and DTR modem control lines.
  Optional — return `{:error, :not_supported}` if the adapter doesn't
  support modem pin control.
  """
  @callback get_modem_pins(handle()) ::
              {:ok, %{rts: boolean(), dtr: boolean()}} | {:error, term()}

  @typedoc "Internal atom form of the `SerialProxyRequestType` enum."
  @type request_type :: :subscribe | :unsubscribe | :flush

  @typedoc "Internal atom form of the `SerialProxyStatus` enum."
  @type request_status :: :ok | :assumed_success | :error | :timeout | :not_supported

  @doc """
  Handle one of the `SerialProxyRequest` operations (subscribe,
  unsubscribe, flush) and return a status for the client. Optional —
  when undefined, espex responds with `:not_supported`.

  Subscribe/unsubscribe are currently no-ops in the default espex flow
  (data delivery is wired at `c:open/3` time); adapters that care about
  explicit stream control can implement the toggle here.
  """
  @callback request(handle(), request_type()) ::
              {:ok, request_status()} | {:error, term()}

  @optional_callbacks set_modem_pins: 3, get_modem_pins: 1, request: 2
end
