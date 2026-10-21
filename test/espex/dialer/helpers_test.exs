defmodule Espex.Dialer.HelpersTest do
  use ExUnit.Case, async: true

  alias Espex.Dialer.{Backoff, Target}

  describe "Backoff" do
    test "doubles from 5 s up to 300 s" do
      schedule = Enum.scan(1..8, Backoff.initial(), fn _, b -> Backoff.next(b) end)

      assert [Backoff.initial() | schedule] |> Enum.take(9) == [
               5_000,
               10_000,
               20_000,
               40_000,
               80_000,
               160_000,
               300_000,
               300_000,
               300_000
             ]
    end

    test "jitter is uniform within ±20 %" do
      # The random function picks from 0..2000: 2001 values around 5 s.
      assert Backoff.jittered(5_000, fn 2_001 -> 0 end) == 4_000
      assert Backoff.jittered(5_000, fn 2_001 -> 2_000 end) == 6_000

      for _ <- 1..200 do
        assert Backoff.jittered(10_000) in 8_000..12_000
      end
    end
  end

  describe "Target" do
    test "parses IP strings and tuples, not names" do
      assert Target.parse("192.168.1.10") == {:ok, {192, 168, 1, 10}}
      assert Target.parse({10, 0, 0, 1}) == {:ok, {10, 0, 0, 1}}
      assert Target.parse("2001:db8::1") == {:ok, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}}
      assert {:error, message} = Target.parse("homeassistant.local")
      assert message =~ "no DNS"
      assert {:error, _} = Target.parse({256, 0, 0, 1})
      assert {:error, _} = Target.parse(nil)
    end

    test "a v4-mapped address becomes IPv4" do
      assert Target.parse("::ffff:192.168.1.10") == {:ok, {192, 168, 1, 10}}
      assert Target.from_peer({{0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x010A}, 40_000}) == {:ok, {192, 168, 1, 10}}
    end

    test "link-local IPv6 is refused" do
      assert {:error, message} = Target.parse("fe80::1")
      assert message =~ "link-local"
      assert {:error, _} = Target.from_peer({{0xFEBF, 0, 0, 0, 0, 0, 0, 1}, 1})
      assert {:ok, _} = Target.from_peer({{0xFEC0, 0, 0, 0, 0, 0, 0, 1}, 1})
    end

    test "a non-IP peer has no target" do
      assert {:error, _} = Target.from_peer({:local, "/tmp/sock"})
    end
  end
end
