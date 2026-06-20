defmodule Espex.PskStore do
  @moduledoc """
  Behaviour for persisting the Noise pre-shared key when Home Assistant
  provisions or rotates it at runtime via `NoiseEncryptionSetKeyRequest`.

  Espex itself holds the active PSK in `Espex.Server` and applies a new
  key to the *next* connection automatically — but it has no opinion on
  durability. Without a store, a provisioned key is lost on restart
  (espex logs a warning and applies it anyway). Configure a `:psk_store`
  adapter to own persistence: write the 32 raw bytes wherever your host
  app keeps secrets (a file, NVS, a database row, a secrets manager),
  and load them back into `:psk` / `device_config` on boot.

  ## Callback

  `c:store_psk/1` is invoked with the new 32-byte key *before* espex
  applies it. Return `:ok` to proceed (espex then updates the running
  server and replies `success: true` to the client). Return
  `{:error, reason}` to abort — espex skips the server update and replies
  `success: false`, so a failed write never silently drops the key.

  ## Example

      defmodule MyApp.FilePskStore do
        @behaviour Espex.PskStore

        @path "/data/espex_psk.bin"

        @impl Espex.PskStore
        def store_psk(<<_::256>> = psk) do
          File.write(@path, psk)
        end

        @doc "Call on boot to seed device_config from the persisted key."
        def load_psk do
          case File.read(@path) do
            {:ok, <<_::256>> = psk} -> psk
            _ -> nil
          end
        end
      end

  ## Wiring

  Pass the module as the `:psk_store` adapter, and seed `device_config`
  from it on boot so a previously provisioned key survives restart:

      psk = MyApp.FilePskStore.load_psk()

      children = [
        {Espex,
         name: MyApp.EspexSup,
         server_name: MyApp.EspexServer,
         device_config: [name: "my-device", psk: psk, accepts_key_provisioning: psk == nil],
         psk_store: MyApp.FilePskStore}
      ]

  Here `accepts_key_provisioning` is opened only while still keyless, so
  the plaintext bootstrap path is available exactly until a key exists.
  """

  @doc """
  Persist the newly provisioned 32-byte Noise PSK.

  Called before espex applies the key to the running server. Return
  `:ok` to proceed or `{:error, reason}` to abort the update.
  """
  @callback store_psk(psk :: <<_::256>>) :: :ok | {:error, term()}
end
