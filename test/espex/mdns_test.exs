defmodule Espex.MdnsTest do
  use ExUnit.Case, async: true

  alias Espex.DeviceConfig

  describe "DeviceConfig.to_mdns_service/1" do
    test "builds the _esphomelib._tcp service shape with every TXT record set" do
      config =
        DeviceConfig.new(
          name: "my-dev",
          friendly_name: "My Dev",
          mac_address: "AA:BB:CC:DD:EE:FF",
          esphome_version: "2026.1.0",
          project_name: "acme.thing",
          project_version: "1.2.3",
          port: 6053
        )

      svc = DeviceConfig.to_mdns_service(config)

      assert svc.id == :esphomelib
      assert svc.instance_name == :unspecified
      assert svc.protocol == "esphomelib"
      assert svc.transport == "tcp"
      assert svc.port == 6053

      assert "mac=AA:BB:CC:DD:EE:FF" in svc.txt_payload
      assert "version=2026.1.0" in svc.txt_payload
      assert "friendly_name=My Dev" in svc.txt_payload
      assert "project_name=acme.thing" in svc.txt_payload
      assert "project_version=1.2.3" in svc.txt_payload
    end

    test "empty-string fields are omitted from the TXT payload" do
      config =
        DeviceConfig.new(
          mac_address: "AA:BB:CC:DD:EE:FF",
          esphome_version: "2026.1.0",
          # friendly_name, project_name, project_version left as "" defaults
          friendly_name: "",
          project_name: "",
          project_version: ""
        )

      svc = DeviceConfig.to_mdns_service(config)

      refute Enum.any?(svc.txt_payload, &String.starts_with?(&1, "friendly_name="))
      refute Enum.any?(svc.txt_payload, &String.starts_with?(&1, "project_name="))
      refute Enum.any?(svc.txt_payload, &String.starts_with?(&1, "project_version="))

      assert "mac=AA:BB:CC:DD:EE:FF" in svc.txt_payload
      assert "version=2026.1.0" in svc.txt_payload
    end
  end

  describe "Espex.Mdns.MdnsLite adapter" do
    test "declares the Espex.Mdns behaviour" do
      behaviours =
        Espex.Mdns.MdnsLite.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Espex.Mdns in behaviours
    end

    test "advertise forwards to MdnsLite when it's loaded (it is in the test env)" do
      # :mdns_lite is a test-only dep so MdnsLite should always be loaded
      # when running `mix test`. The actual registration side effect is
      # exercised in mdns_integration_test; here we just verify the code
      # path doesn't early-return with :mdns_lite_not_loaded.
      svc = DeviceConfig.new() |> DeviceConfig.to_mdns_service() |> Map.put(:port, 16_053)

      assert :ok = Espex.Mdns.MdnsLite.advertise(svc)
      assert :ok = Espex.Mdns.MdnsLite.withdraw(svc.id)
    end
  end
end
