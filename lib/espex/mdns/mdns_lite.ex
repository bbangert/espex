defmodule Espex.Mdns.MdnsLite do
  @moduledoc """
  Default `Espex.Mdns` adapter backed by the
  [`:mdns_lite`](https://hex.pm/packages/mdns_lite) library — the mDNS
  responder shipped with Nerves.

  Espex does **not** declare `:mdns_lite` as a runtime dependency; this
  module uses late-binding (`Code.ensure_loaded?/1` + `apply/3`) so the
  espex library compiles and loads on systems that don't have it. If a
  consumer wires this adapter without pulling `:mdns_lite` into their
  own deps, `c:advertise/1` returns `{:error, :mdns_lite_not_loaded}`
  instead of crashing with `UndefinedFunctionError`.

  ## Usage

  Add `:mdns_lite` to your own application's deps:

      # mix.exs
      {:mdns_lite, "~> 0.8"}

  then wire the adapter:

      Espex.start_link(
        device_config: [name: "my-device", ...],
        mdns: Espex.Mdns.MdnsLite
      )
  """

  @behaviour Espex.Mdns

  # Silence the "module not available" warning at compile time; the
  # adapter handles MdnsLite being absent explicitly at runtime via
  # Code.ensure_loaded?/1.
  @compile {:no_warn_undefined, MdnsLite}

  @impl Espex.Mdns
  def advertise(service) do
    if Code.ensure_loaded?(MdnsLite) do
      MdnsLite.add_mdns_service(service)
    else
      {:error, :mdns_lite_not_loaded}
    end
  end

  @impl Espex.Mdns
  def withdraw(service_id) do
    if Code.ensure_loaded?(MdnsLite) do
      MdnsLite.remove_mdns_service(service_id)
    end

    :ok
  end
end
