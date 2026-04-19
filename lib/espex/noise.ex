defmodule Espex.Noise do
  @moduledoc """
  Pure implementation of the `Noise_NNpsk0_25519_ChaChaPoly_SHA256`
  handshake + transport cipher, as used by the ESPHome Native API.

  Everything here is side-effect free except for Curve25519 keypair
  generation (`:crypto.generate_key/2`) inside `write_message/2` — tests
  can inject a deterministic keypair via the `:ephemeral` option to
  `init/3` to get fully reproducible handshakes.

  ## Shape

      {:ok, responder} = Noise.init(:responder, psk, "NoiseAPIInit\\x00\\x00")
      {:ok, responder, _empty_payload} = Noise.read_message(responder, client_msg1)
      {:ok, responder, server_msg2} = Noise.write_message(responder, "")
      {:ok, tx, rx} = Noise.split(responder)

      {:ok, tx, ciphertext} = Noise.encrypt(tx, "", "hello")
      {:ok, rx, "hello"} = Noise.decrypt(rx, "", ciphertext)

  ## References

  * Noise Protocol Framework revision 34 (https://noiseprotocol.org/noise.html)
  * ESPHome api noise frame helper (for ESPHome-specific wire integration;
    that lives in `Espex.Noise.Frame`, not here)
  """

  @protocol_name "Noise_NNpsk0_25519_ChaChaPoly_SHA256"
  @dh_len 32
  @tag_len 16

  @type role :: :initiator | :responder

  @typedoc """
  Handshake state. Opaque to callers; passed back into the library
  between operations.
  """
  @type handshake :: %__MODULE__{
          role: role(),
          h: <<_::256>>,
          ck: <<_::256>>,
          k: <<_::256>> | nil,
          n: non_neg_integer(),
          e_pub: binary() | nil,
          e_priv: binary() | nil,
          re: binary() | nil,
          psk: <<_::256>>,
          step: non_neg_integer()
        }

  @typedoc "Post-handshake cipher state for one direction."
  @type cipher :: %{k: <<_::256>>, n: non_neg_integer()}

  defstruct [:role, :h, :ck, :k, :n, :e_pub, :e_priv, :re, :psk, :step]

  @doc """
  Initialise a handshake as initiator or responder.

  `psk` must be exactly 32 bytes. `prologue` is any binary — for ESPHome
  it's `"NoiseAPIInit\\x00\\x00"`. Pass `ephemeral: {pub, priv}` to
  override the generated keypair (testing only).
  """
  @spec init(role(), <<_::256>>, binary()) :: {:ok, handshake()} | {:error, term()}
  def init(role, psk, prologue) when role in [:initiator, :responder] do
    cond do
      not is_binary(psk) or byte_size(psk) != 32 ->
        {:error, :invalid_psk_length}

      not is_binary(prologue) ->
        {:error, :invalid_prologue}

      true ->
        ck = :crypto.hash(:sha256, @protocol_name)
        h = mix_hash_bytes(ck, prologue)

        state = %__MODULE__{
          role: role,
          h: h,
          ck: ck,
          k: nil,
          n: 0,
          psk: psk,
          step: 0
        }

        {:ok, state}
    end
  end

  @doc """
  Produce the next outbound handshake message.

  Call once per message the local role is expected to write, in order.
  For `Noise_NNpsk0`:

    * initiator: first call returns `message 1` (`psk, e`)
    * responder: first call returns `message 2` (`e, ee`)

  Returns the updated state plus the encoded handshake message bytes
  ready for the wire.
  """
  @spec write_message(handshake(), binary(), keyword()) ::
          {:ok, handshake(), binary()} | {:error, term()}
  def write_message(handshake, payload \\ <<>>, opts \\ [])

  # -> psk, e
  # PSK-extension to the `e` token: on any PSK handshake, MixKey(e.public)
  # is called in addition to MixHash. See Noise spec §9.2.
  def write_message(%__MODULE__{role: :initiator, step: 0} = state, payload, opts) do
    {e_pub, e_priv} = keypair(opts)
    psk = state.psk
    state = %{state | e_pub: e_pub, e_priv: e_priv}

    {state, ct} =
      state
      |> mix_key_and_hash(psk)
      |> mix_hash(e_pub)
      |> mix_key(e_pub)
      |> encrypt_and_hash(payload)

    {:ok, %{state | step: 1}, e_pub <> ct}
  end

  # <- e, ee  (after having read the initiator's first message)
  # PSK-extension to the `e` token (see Noise spec §9.2).
  def write_message(%__MODULE__{role: :responder, step: 1} = state, payload, opts) do
    {e_pub, e_priv} = keypair(opts)
    shared = dh(e_priv, state.re)
    state = %{state | e_pub: e_pub, e_priv: e_priv}

    {state, ct} =
      state
      |> mix_hash(e_pub)
      |> mix_key(e_pub)
      |> mix_key(shared)
      |> encrypt_and_hash(payload)

    {:ok, %{state | step: 2}, e_pub <> ct}
  end

  def write_message(_state, _payload, _opts), do: {:error, :wrong_step}

  @doc """
  Consume the next inbound handshake message.

  Returns the updated state plus the decrypted payload (empty for both
  ESPHome handshake messages, but included for generality).
  """
  @spec read_message(handshake(), binary()) :: {:ok, handshake(), binary()} | {:error, term()}
  def read_message(handshake, message)

  # -> psk, e
  # PSK-extension to the `e` token (see Noise spec §9.2).
  def read_message(%__MODULE__{role: :responder, step: 0} = state, <<re::binary-size(@dh_len), rest::binary>>) do
    psk = state.psk
    state = %{state | re: re}

    state =
      state
      |> mix_key_and_hash(psk)
      |> mix_hash(re)
      |> mix_key(re)

    with {:ok, state, payload} <- decrypt_and_hash(state, rest) do
      {:ok, %{state | step: 1}, payload}
    end
  end

  # <- e, ee
  # PSK-extension to the `e` token (see Noise spec §9.2).
  def read_message(%__MODULE__{role: :initiator, step: 1} = state, <<re::binary-size(@dh_len), rest::binary>>) do
    shared = dh(state.e_priv, re)
    state = %{state | re: re}

    state =
      state
      |> mix_hash(re)
      |> mix_key(re)
      |> mix_key(shared)

    with {:ok, state, payload} <- decrypt_and_hash(state, rest) do
      {:ok, %{state | step: 2}, payload}
    end
  end

  def read_message(_state, _msg), do: {:error, :wrong_step_or_bad_message}

  @doc """
  Split the completed handshake into two `cipher` states — one for
  sending, one for receiving — per the Noise spec.

  Only call after both handshake messages have been processed (i.e.
  `step == 2`). For the initiator the first cipher is used to
  send and the second to receive; for the responder, flipped.
  """
  @spec split(handshake()) :: {:ok, tx :: cipher(), rx :: cipher()} | {:error, term()}
  def split(%__MODULE__{step: 2, role: role, ck: ck}) do
    <<k1::binary-size(32), k2::binary-size(32)>> = hkdf(ck, <<>>, 2)

    case role do
      :initiator -> {:ok, %{k: k1, n: 0}, %{k: k2, n: 0}}
      :responder -> {:ok, %{k: k2, n: 0}, %{k: k1, n: 0}}
    end
  end

  def split(_state), do: {:error, :handshake_incomplete}

  @doc """
  Encrypt a payload with the given cipher state. Returns the updated
  cipher (with nonce incremented) plus the ciphertext.

  `ad` and `plaintext` may be `iodata()` — the underlying AEAD accepts
  it directly, so callers can hand in pre-split iolists without
  collapsing them to a binary first.
  """
  @spec encrypt(cipher(), iodata(), iodata()) :: {:ok, cipher(), binary()}
  def encrypt(%{k: k, n: n} = cipher, ad, plaintext) do
    {ct, tag} =
      :crypto.crypto_one_time_aead(:chacha20_poly1305, k, nonce_bytes(n), plaintext, ad, @tag_len, true)

    {:ok, %{cipher | n: n + 1}, ct <> tag}
  end

  @doc """
  Decrypt a ciphertext with the given cipher state.
  """
  @spec decrypt(cipher(), iodata(), binary()) ::
          {:ok, cipher(), binary()} | {:error, :auth_failed | :ciphertext_too_short}
  def decrypt(%{k: k, n: n} = cipher, ad, ciphertext) when byte_size(ciphertext) >= @tag_len do
    split = byte_size(ciphertext) - @tag_len
    <<ct::binary-size(split), tag::binary-size(@tag_len)>> = ciphertext

    case :crypto.crypto_one_time_aead(:chacha20_poly1305, k, nonce_bytes(n), ct, ad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, %{cipher | n: n + 1}, plaintext}
      :error -> {:error, :auth_failed}
    end
  end

  def decrypt(_cipher, _ad, _ct), do: {:error, :ciphertext_too_short}

  # ---------------------------------------------------------------------------
  # Symmetric state ops (MixHash / MixKey / MixKeyAndHash / EncryptAndHash)
  # ---------------------------------------------------------------------------

  defp mix_hash(%__MODULE__{h: h} = state, data), do: %{state | h: mix_hash_bytes(h, data)}

  # :crypto.hash accepts iodata, so passing [h, data] avoids an h <> data
  # copy on every MixHash call (the handshake performs roughly half a dozen).
  defp mix_hash_bytes(h, data), do: :crypto.hash(:sha256, [h, data])

  defp mix_key(%__MODULE__{ck: ck} = state, ikm) do
    <<new_ck::binary-size(32), temp_k::binary-size(32)>> = hkdf(ck, ikm, 2)
    %{state | ck: new_ck, k: temp_k, n: 0}
  end

  defp mix_key_and_hash(%__MODULE__{ck: ck, h: h} = state, ikm) do
    <<new_ck::binary-size(32), tmp_h::binary-size(32), temp_k::binary-size(32)>> = hkdf(ck, ikm, 3)
    %{state | ck: new_ck, h: mix_hash_bytes(h, tmp_h), k: temp_k, n: 0}
  end

  # In Noise_NNpsk0, the `psk` token at message position 0 always sets `k`
  # before any encrypt_and_hash / decrypt_and_hash call. The generic
  # "k not yet established" branches from the Noise spec are therefore
  # unreachable in this pattern and omitted.
  defp encrypt_and_hash(%__MODULE__{k: k, n: n, h: h} = state, plaintext) do
    {ct, tag} =
      :crypto.crypto_one_time_aead(:chacha20_poly1305, k, nonce_bytes(n), plaintext, h, @tag_len, true)

    out = ct <> tag
    {mix_hash(%{state | n: n + 1}, out), out}
  end

  defp decrypt_and_hash(%__MODULE__{k: k, n: n, h: h} = state, ciphertext)
       when byte_size(ciphertext) >= @tag_len do
    split = byte_size(ciphertext) - @tag_len
    <<ct::binary-size(split), tag::binary-size(@tag_len)>> = ciphertext

    case :crypto.crypto_one_time_aead(:chacha20_poly1305, k, nonce_bytes(n), ct, h, tag, false) do
      pt when is_binary(pt) ->
        {:ok, mix_hash(%{state | n: n + 1}, ciphertext), pt}

      :error ->
        {:error, :auth_failed}
    end
  end

  defp decrypt_and_hash(_state, _ct), do: {:error, :ciphertext_too_short}

  # ---------------------------------------------------------------------------
  # Primitives
  # ---------------------------------------------------------------------------

  # HKDF-SHA256 returning num_outputs blocks of 32 bytes.
  defp hkdf(ck, ikm, num_outputs) when num_outputs in [2, 3] do
    prk = :crypto.mac(:hmac, :sha256, ck, ikm)
    t1 = :crypto.mac(:hmac, :sha256, prk, <<1>>)
    t2 = :crypto.mac(:hmac, :sha256, prk, t1 <> <<2>>)

    case num_outputs do
      2 ->
        t1 <> t2

      3 ->
        t3 = :crypto.mac(:hmac, :sha256, prk, t2 <> <<3>>)
        t1 <> t2 <> t3
    end
  end

  # ChaCha20-Poly1305 nonce per Noise: 4 zero bytes + 8-byte LE counter.
  defp nonce_bytes(n) when is_integer(n) and n >= 0, do: <<0::32, n::little-64>>

  defp dh(priv, peer_pub) do
    :crypto.compute_key(:ecdh, peer_pub, priv, :x25519)
  end

  defp keypair(opts) do
    case Keyword.get(opts, :ephemeral) do
      {pub, priv} when is_binary(pub) and is_binary(priv) -> {pub, priv}
      nil -> :crypto.generate_key(:ecdh, :x25519)
    end
  end

  @doc false
  def protocol_name, do: @protocol_name
end
