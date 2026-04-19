defmodule Espex.SerialProxy do
  @moduledoc """
  Behaviour for serial proxy adapters.

  Implement this module to expose one or more serial ports to ESPHome
  clients through the Native API's serial proxy feature. Home Assistant
  can then talk to the port over the network as though it were local —
  useful for Zigbee coordinators, CLI debug ports, and similar
  "tunnel a UART through the device" use cases.

  Espex itself owns no port state. It calls your callbacks from the
  per-connection handler process when a client configures, writes to,
  or closes an instance.

  ## Callbacks

  | Callback | Required | Purpose |
  |----------|----------|---------|
  | `c:list_instances/0` | yes | Advertise the available ports |
  | `c:open/3` | yes | Open an instance with the client's requested UART params |
  | `c:write/2` | yes | Write bytes to an opened instance |
  | `c:close/1` | yes | Close and release an instance |
  | `c:set_modem_pins/3` | no | Toggle RTS/DTR |
  | `c:get_modem_pins/1` | no | Read RTS/DTR |
  | `c:request/2` | no | Handle subscribe / unsubscribe / flush |

  The three optional callbacks are each reported to the client as
  `:not_supported` when omitted — your adapter can safely ignore them if
  the hardware can't do modem-pin control or drain-flush.

  ## Data flow

  After a successful `c:open/3`, data arriving on the port must be sent
  to the `subscriber` pid (the per-connection handler) as:

      {:espex_serial_data, handle, binary}

  `handle` is the opaque term you returned from `c:open/3` — typically
  a pid, reference, or small tuple. The handler uses it to correlate
  the data back to an instance id.

  The client can later change port parameters by issuing another
  configure request; the connection handler will `close/1` the existing
  handle and call `open/3` again with the new options. Your adapter
  doesn't need to handle reconfigure-in-place.

  ## `open_opts` reference

  `c:open/3` receives a keyword list shaped like `t:open_opts/0`:

  | Key | Values | Default when the client sends 0 |
  |-----|--------|---------------------------------|
  | `:speed` | baud rate | `9600` |
  | `:data_bits` | `5`, `6`, `7`, `8` | `8` |
  | `:stop_bits` | `1`, `2` | `1` |
  | `:parity` | `:none`, `:even`, `:odd` | `:none` |
  | `:flow_control` | `:none`, `:hardware` | `:none` |

  The defaults follow common "9600-8-N-1" convention and match what
  ESPHome uses when fields are omitted from a `SerialProxyConfigureRequest`.
  Use `configure_request_to_open_opts/1` if you're building your own
  message-routing test harness; the connection handler calls it for
  you in normal operation.

  ## `SerialProxy.Info` for advertisements

  `c:list_instances/0` returns a list of `Espex.SerialProxy.Info`
  structs, one per port. Each needs:

    * `instance` — stable `non_neg_integer()` id; the client refers to
      ports by this id in all subsequent requests
    * `name` — display name shown in the Home Assistant UI
    * `port_type` — `:ttl`, `:rs232`, or `:rs485`

  The list is snapshotted at connection-accept time and cached by the
  client; see the "Architecture" guide for why changes require a
  reconnect.

  ## Example: a port wrapping Circuits.UART

  The following sketch wires a single port (`/dev/ttyUSB0`) to a
  Zigbee-style advertisement. It assumes a real `Circuits.UART`-like
  library is available; adapt to whichever serial library you use.

      defmodule MyApp.SerialAdapter do
        @behaviour Espex.SerialProxy

        @impl true
        def list_instances do
          [Espex.SerialProxy.Info.new(instance: 0, name: "zigbee", port_type: :ttl)]
        end

        @impl true
        def open(0, opts, subscriber) do
          {:ok, pid} = MyApp.SerialPort.start_link(
            device: "/dev/ttyUSB0",
            subscriber: subscriber,
            speed: opts[:speed],
            data_bits: opts[:data_bits],
            stop_bits: opts[:stop_bits],
            parity: opts[:parity],
            flow_control: opts[:flow_control]
          )
          {:ok, pid}
        end

        def open(_unknown, _opts, _subscriber), do: {:error, :no_such_instance}

        @impl true
        def write(pid, data), do: MyApp.SerialPort.write(pid, data)

        @impl true
        def close(pid) do
          _ = MyApp.SerialPort.stop(pid)
          :ok
        end

        @impl true
        def set_modem_pins(pid, rts, dtr), do: MyApp.SerialPort.set_pins(pid, rts: rts, dtr: dtr)

        @impl true
        def get_modem_pins(pid), do: MyApp.SerialPort.get_pins(pid)

        @impl true
        def request(pid, :flush), do: MyApp.SerialPort.flush(pid)
        def request(_pid, _), do: {:ok, :not_supported}
      end

  And inside the wrapper GenServer (`MyApp.SerialPort`), any time your
  read loop gets a chunk from the OS, forward it to the subscriber:

      send(state.subscriber, {:espex_serial_data, self(), chunk})

  ## `request/2` semantics

  The optional `c:request/2` callback handles the three operations the
  ESPHome wire protocol exposes:

    * `:subscribe` / `:unsubscribe` — espex already wires data delivery
      at `c:open/3` time via the `subscriber` pid. Most adapters can
      return `{:ok, :not_supported}` or `{:ok, :ok}` here. Implement
      them only if your adapter keeps a separate stream-enabled flag
      you want the client to toggle explicitly.
    * `:flush` — block until all queued TX data has been drained. Return
      `{:ok, :ok}` if you confirmed the drain, `{:ok, :assumed_success}`
      if the platform can't report completion, `{:ok, :timeout}` if you
      gave up waiting, or `{:error, reason}` on failure.

  When you don't define `c:request/2` at all, espex responds with
  `:not_supported` to every request type automatically.

  ## Wiring

  Pass your adapter module to `Espex.start_link/1`:

      Espex.start_link(
        device_config: [name: "serial-gateway"],
        serial_proxy: MyApp.SerialAdapter
      )
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
