defmodule Espex.NoiseTest do
  use ExUnit.Case, async: true

  alias Espex.Noise

  @psk :crypto.hash(:sha256, "espex-noise-test-psk")
  @prologue "NoiseAPIInit" <> <<0, 0>>

  describe "interop vector (Python noiseprotocol reference)" do
    # Reference bytes were produced by the Python `noiseprotocol` library — the
    # same library aioesphomeapi / Home Assistant use. Fixing all inputs
    # (PSK = 32 zero bytes, ephemeral private = 32 x 0x11, prologue as below,
    # empty payload) makes write_message deterministic, so this pins exact
    # byte-level compatibility with the reference implementation.
    #
    # Regenerate via `python3 test/manual/noise_vector.py` (re-add the script
    # if it's been removed).
    test "initiator write_message(empty) matches the reference handshake bytes" do
      psk = :binary.copy(<<0x00>>, 32)
      e_priv = :binary.copy(<<0x11>>, 32)
      {e_pub, _} = :crypto.generate_key(:ecdh, :x25519, e_priv)

      {:ok, state} = Noise.init(:initiator, psk, @prologue)
      {:ok, _state, msg1} = Noise.write_message(state, <<>>, ephemeral: {e_pub, e_priv})

      expected =
        Base.decode16!(
          "7b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13" <>
            "74dad7c1fff2bd7faa65ad4ac3b80bb9",
          case: :lower
        )

      assert msg1 == expected
    end
  end

  describe "init/3" do
    test "accepts initiator or responder with valid inputs" do
      assert {:ok, %Noise{role: :initiator, step: 0}} = Noise.init(:initiator, @psk, @prologue)
      assert {:ok, %Noise{role: :responder, step: 0}} = Noise.init(:responder, @psk, @prologue)
    end

    test "rejects a PSK of wrong length" do
      assert {:error, :invalid_psk_length} = Noise.init(:responder, <<0::31*8>>, @prologue)
      assert {:error, :invalid_psk_length} = Noise.init(:responder, "short", @prologue)
    end

    test "rejects non-binary prologue" do
      assert {:error, :invalid_prologue} = Noise.init(:responder, @psk, :not_binary)
    end

    test "h and ck are deterministic given psk + prologue" do
      {:ok, a} = Noise.init(:initiator, @psk, @prologue)
      {:ok, b} = Noise.init(:responder, @psk, @prologue)
      assert a.h == b.h
      assert a.ck == b.ck
    end
  end

  describe "handshake round-trip" do
    test "initiator and responder reach identical split keys" do
      {:ok, i} = Noise.init(:initiator, @psk, @prologue)
      {:ok, r} = Noise.init(:responder, @psk, @prologue)

      {:ok, i, msg1} = Noise.write_message(i, <<>>)
      assert byte_size(msg1) == 32 + 16

      {:ok, r, payload1} = Noise.read_message(r, msg1)
      assert payload1 == <<>>

      {:ok, r, msg2} = Noise.write_message(r, <<>>)
      assert byte_size(msg2) == 32 + 16

      {:ok, i, payload2} = Noise.read_message(i, msg2)
      assert payload2 == <<>>

      {:ok, i_tx, i_rx} = Noise.split(i)
      {:ok, r_tx, r_rx} = Noise.split(r)

      # Initiator's send key matches responder's receive key and vice versa.
      assert i_tx.k == r_rx.k
      assert i_rx.k == r_tx.k
      assert i_tx.k != i_rx.k
    end

    test "handshake payloads round-trip through the AEAD-wrapped payload slot" do
      {:ok, i} = Noise.init(:initiator, @psk, @prologue)
      {:ok, r} = Noise.init(:responder, @psk, @prologue)

      {:ok, i, msg1} = Noise.write_message(i, "hello from initiator")
      {:ok, r, received1} = Noise.read_message(r, msg1)
      assert received1 == "hello from initiator"

      {:ok, _r, msg2} = Noise.write_message(r, "hello from responder")
      {:ok, _i, received2} = Noise.read_message(i, msg2)
      assert received2 == "hello from responder"
    end

    test "different PSKs produce handshakes that fail to decrypt each other" do
      {:ok, i} = Noise.init(:initiator, @psk, @prologue)
      {:ok, r} = Noise.init(:responder, :crypto.hash(:sha256, "a different psk"), @prologue)

      {:ok, _i, msg1} = Noise.write_message(i, <<>>)
      assert {:error, :auth_failed} = Noise.read_message(r, msg1)
    end

    test "different prologues also fail to decrypt" do
      {:ok, i} = Noise.init(:initiator, @psk, "Prologue A")
      {:ok, r} = Noise.init(:responder, @psk, "Prologue B")

      {:ok, _i, msg1} = Noise.write_message(i, <<>>)
      assert {:error, :auth_failed} = Noise.read_message(r, msg1)
    end
  end

  describe "step errors" do
    setup do
      {:ok, i} = Noise.init(:initiator, @psk, @prologue)
      {:ok, r} = Noise.init(:responder, @psk, @prologue)
      {:ok, i: i, r: r}
    end

    test "initiator cannot write message 2 until it has read message 1", %{i: i} do
      {:ok, i, _} = Noise.write_message(i, <<>>)
      # Now i.step == 1, but initiator doesn't write at step 1 in NN pattern.
      assert {:error, :wrong_step} = Noise.write_message(i, <<>>)
    end

    test "responder cannot read message before init", %{r: r} do
      # Responder at step 0 expects client's msg1; a well-formed call works;
      # but a responder at step 1 reading again should fail.
      {:ok, i} = Noise.init(:initiator, @psk, @prologue)
      {:ok, _i, msg1} = Noise.write_message(i, <<>>)
      {:ok, r, _} = Noise.read_message(r, msg1)
      assert {:error, :wrong_step_or_bad_message} = Noise.read_message(r, msg1)
    end

    test "split requires completed handshake", %{i: i} do
      assert {:error, :handshake_incomplete} = Noise.split(i)
    end
  end

  describe "transport encrypt/decrypt" do
    setup do
      {:ok, i} = Noise.init(:initiator, @psk, @prologue)
      {:ok, r} = Noise.init(:responder, @psk, @prologue)
      {:ok, i, msg1} = Noise.write_message(i, <<>>)
      {:ok, r, _} = Noise.read_message(r, msg1)
      {:ok, r, msg2} = Noise.write_message(r, <<>>)
      {:ok, i, _} = Noise.read_message(i, msg2)
      {:ok, i_tx, i_rx} = Noise.split(i)
      {:ok, r_tx, r_rx} = Noise.split(r)
      {:ok, i_tx: i_tx, i_rx: i_rx, r_tx: r_tx, r_rx: r_rx}
    end

    test "initiator→responder encrypted payload decrypts correctly", ctx do
      {:ok, i_tx, ct} = Noise.encrypt(ctx.i_tx, <<>>, "payload one")
      assert {:ok, _r_rx, "payload one"} = Noise.decrypt(ctx.r_rx, <<>>, ct)

      {:ok, _i_tx, ct2} = Noise.encrypt(i_tx, <<>>, "payload two")
      # Nonce advanced — r_rx at n=0 can't decrypt a nonce=1 frame.
      assert {:error, :auth_failed} = Noise.decrypt(ctx.r_rx, <<>>, ct2)
    end

    test "both directions independently advance nonces", ctx do
      {:ok, i_tx, ct_i} = Noise.encrypt(ctx.i_tx, <<>>, "from initiator")
      {:ok, r_tx, ct_r} = Noise.encrypt(ctx.r_tx, <<>>, "from responder")

      assert {:ok, _r_rx, "from initiator"} = Noise.decrypt(ctx.r_rx, <<>>, ct_i)
      assert {:ok, _i_rx, "from responder"} = Noise.decrypt(ctx.i_rx, <<>>, ct_r)

      assert i_tx.n == 1
      assert r_tx.n == 1
    end

    test "tampered ciphertext fails auth", ctx do
      {:ok, _i_tx, ct} = Noise.encrypt(ctx.i_tx, <<>>, "data")
      <<first, rest::binary>> = ct
      tampered = <<Bitwise.bxor(first, 1), rest::binary>>
      assert {:error, :auth_failed} = Noise.decrypt(ctx.r_rx, <<>>, tampered)
    end

    test "AD mismatch fails auth", ctx do
      {:ok, _i_tx, ct} = Noise.encrypt(ctx.i_tx, "context-a", "data")
      assert {:error, :auth_failed} = Noise.decrypt(ctx.r_rx, "context-b", ct)
    end

    test "short ciphertext rejected", ctx do
      assert {:error, :ciphertext_too_short} = Noise.decrypt(ctx.r_rx, <<>>, <<1, 2, 3>>)
    end
  end
end
