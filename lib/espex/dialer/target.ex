defmodule Espex.Dialer.Target do
  @moduledoc false

  # Dial-back addresses, as ESPHome's api config and peer_to_target take
  # them: an IP literal (no DNS), a v4-mapped IPv6 address as IPv4.
  # Link-local IPv6 is refused: gen_tcp's peername gives no scope id, so
  # such an address cannot be dialed back.

  import Bitwise

  @doc "Parse a configured host or target: an IP string or tuple."
  @spec parse(term()) :: {:ok, :inet.ip_address()} | {:error, String.t()}
  def parse(host) when is_binary(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, ip} -> normalise(ip)
      {:error, _} -> {:error, "#{inspect(host)} is not an IP address (no DNS names)"}
    end
  end

  def parse(ip) when is_tuple(ip) do
    if :inet.is_ip_address(ip), do: normalise(ip), else: {:error, "#{inspect(ip)} is not an IP address"}
  end

  def parse(other), do: {:error, "#{inspect(other)} is not an IP address"}

  @doc "A v4-mapped IPv6 address becomes IPv4; link-local IPv6 is refused."
  @spec normalise(:inet.ip_address()) :: {:ok, :inet.ip_address()} | {:error, String.t()}
  def normalise({_, _, _, _} = ip), do: {:ok, ip}

  def normalise({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: {:ok, {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}}

  def normalise({first, _, _, _, _, _, _, _} = ip) when (first &&& 0xFFC0) == 0xFE80,
    do: {:error, "#{:inet.ntoa(ip)} is link-local, which cannot be dialed without a scope id"}

  def normalise({_, _, _, _, _, _, _, _} = ip), do: {:ok, ip}

  @doc "The address to dial back, from a connection's raw peer."
  @spec from_peer(term()) :: {:ok, :inet.ip_address()} | {:error, String.t()}
  def from_peer({ip, port}) when is_tuple(ip) and is_integer(port), do: normalise(ip)
  def from_peer(other), do: {:error, "peer #{inspect(other)} has no IP address"}
end
