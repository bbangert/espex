defmodule Espex.DeviceConfig do
  @moduledoc """
  Data structure representing the ESPHome device identity advertised by this
  server.

  Holds all the fields reported in a `DeviceInfoResponse` when a client
  queries the device over the ESPHome Native API, plus the TCP port the
  server listens on.

  `zwave_feature_flags` and `zwave_home_id` are populated by the consumer
  (typically from an `Espex.ZWaveProxy.Adapter`) before building a
  `DeviceInfoResponse` — the struct itself is pure.

  ## `project_name` format

  If set, `project_name` must follow the ESPHome `"author.project"`
  convention — e.g. `"mycompany.thermostat"`. Home Assistant's ESPHome
  integration splits this string on `.` and indexes `[1]` to derive the
  model name shown in its device registry; a bare token like `"espex"`
  (no dot) makes HA's setup task crash silently and the device never
  registers. The default is `""`, which is what HA treats as "no project"
  and safely skips.
  """

  alias Espex.DeviceConfig.Device
  alias Espex.Proto.DeviceInfoResponse

  @default_port 6053
  @api_version_major 1
  @api_version_minor 10
  @compilation_time (fn ->
                       {{y, mo, d}, {h, mi, s}} = :erlang.universaltime()
                       months = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
                       month = elem(months, mo - 1)
                       pad2 = fn n -> n |> Integer.to_string() |> String.pad_leading(2, "0") end
                       day_str = d |> Integer.to_string() |> String.pad_leading(2)
                       "#{month} #{day_str} #{y}, #{pad2.(h)}:#{pad2.(mi)}:#{pad2.(s)}"
                     end).()

  @type t :: %__MODULE__{
          name: String.t(),
          friendly_name: String.t(),
          mac_address: String.t(),
          esphome_version: String.t(),
          compilation_time: String.t(),
          model: String.t(),
          manufacturer: String.t(),
          suggested_area: String.t(),
          project_name: String.t(),
          project_version: String.t(),
          port: non_neg_integer(),
          zwave_feature_flags: non_neg_integer(),
          zwave_home_id: non_neg_integer(),
          devices: [Device.t()]
        }

  defstruct name: "espex",
            friendly_name: "Espex",
            mac_address: "00:00:00:00:00:00",
            esphome_version: "2026.1.0",
            compilation_time: @compilation_time,
            model: "Espex",
            manufacturer: "Espex",
            suggested_area: "",
            project_name: "",
            project_version: "",
            port: @default_port,
            zwave_feature_flags: 0,
            zwave_home_id: 0,
            devices: []

  @doc """
  Build a new `%DeviceConfig{}` from keyword options.

  Any key not provided uses the default value. If `:mac_address` is not
  provided, the hardware address of the first network interface is
  detected automatically at runtime.

  ## Examples

      Espex.DeviceConfig.new(name: "my-device", port: 6054)

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :mac_address, &detect_mac_address/0)
    struct!(__MODULE__, opts)
  end

  @doc """
  Returns the API version major number this server advertises.
  """
  @spec api_version_major() :: non_neg_integer()
  def api_version_major, do: @api_version_major

  @doc """
  Returns the API version minor number this server advertises.
  """
  @spec api_version_minor() :: non_neg_integer()
  def api_version_minor, do: @api_version_minor

  @doc """
  Convert this config to a `DeviceInfoResponse` protobuf struct.

  Accepts an optional list of `%SerialProxyInfo{}` structs to populate
  the `serial_proxies` field in the response. Sub-devices (if any) come
  from the `:devices` field on the config.
  """
  @spec to_device_info_response(t(), [struct()]) :: DeviceInfoResponse.t()
  def to_device_info_response(%__MODULE__{} = config, serial_proxies \\ []) do
    %DeviceInfoResponse{
      name: config.name,
      friendly_name: config.friendly_name,
      mac_address: config.mac_address,
      esphome_version: config.esphome_version,
      compilation_time: config.compilation_time,
      model: config.model,
      manufacturer: config.manufacturer,
      suggested_area: config.suggested_area,
      project_name: config.project_name,
      project_version: config.project_version,
      webserver_port: 0,
      has_deep_sleep: false,
      uses_password: false,
      api_encryption_supported: false,
      zwave_proxy_feature_flags: config.zwave_feature_flags,
      zwave_home_id: config.zwave_home_id,
      serial_proxies: serial_proxies,
      devices: Enum.map(config.devices, &Device.to_proto/1)
    }
  end

  @doc """
  Build the server info string used in `HelloResponse`.
  """
  @spec server_info(t()) :: String.t()
  def server_info(%__MODULE__{} = config) do
    "#{config.project_name} #{config.project_version} (#{config.esphome_version})"
  end

  @doc """
  Build an mDNS service map suitable for `MdnsLite.add_mdns_service/1`.

  Advertises the `_esphomelib._tcp` service with TXT records containing
  the device identity fields that ESPHome clients use for discovery.
  """
  @spec to_mdns_service(t()) :: map()
  def to_mdns_service(%__MODULE__{} = config) do
    txt =
      [
        {"mac", config.mac_address},
        {"version", config.esphome_version},
        {"friendly_name", config.friendly_name},
        {"project_name", config.project_name},
        {"project_version", config.project_version}
      ]
      |> Enum.reject(fn {_k, v} -> v == "" or is_nil(v) end)
      |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)

    %{
      id: :esphomelib,
      instance_name: :unspecified,
      protocol: "esphomelib",
      transport: "tcp",
      port: config.port,
      txt_payload: txt
    }
  end

  @doc """
  Detect the MAC address from the first available network interface.

  Tries `eth0`, `end0`, and `wlan0` in order, then falls back to the
  first non-loopback interface with a non-zero hardware address. Returns
  the address as an `"AA:BB:CC:DD:EE:FF"` string, or
  `"00:00:00:00:00:00"` if no suitable interface is found.
  """
  @spec detect_mac_address() :: String.t()
  def detect_mac_address do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        find_hwaddr(ifaddrs, [~c"eth0", ~c"end0", ~c"wlan0"]) ||
          find_first_hwaddr(ifaddrs) ||
          "00:00:00:00:00:00"

      _ ->
        "00:00:00:00:00:00"
    end
  end

  defp find_hwaddr(ifaddrs, candidates) do
    Enum.find_value(candidates, fn name ->
      case List.keyfind(ifaddrs, name, 0) do
        {_name, opts} -> format_hwaddr(Keyword.get(opts, :hwaddr))
        nil -> nil
      end
    end)
  end

  defp find_first_hwaddr(ifaddrs) do
    Enum.find_value(ifaddrs, fn {name, opts} ->
      if name != ~c"lo" do
        format_hwaddr(Keyword.get(opts, :hwaddr))
      end
    end)
  end

  defp format_hwaddr([_ | _] = hwaddr) when length(hwaddr) == 6 do
    if Enum.all?(hwaddr, &(&1 == 0)) do
      nil
    else
      hwaddr
      |> Enum.map_join(":", fn byte ->
        byte |> Integer.to_string(16) |> String.pad_leading(2, "0")
      end)
      |> String.upcase()
    end
  end

  defp format_hwaddr(_), do: nil
end
