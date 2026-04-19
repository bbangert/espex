defmodule Espex.Proto.APISourceType do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto2

  field(:SOURCE_BOTH, 0)
  field(:SOURCE_SERVER, 1)
  field(:SOURCE_CLIENT, 2)
end

defmodule Espex.Proto.PbExtension do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto2

  extend(Google.Protobuf.MethodOptions, :needs_setup_connection, 1038,
    optional: true,
    type: :bool,
    json_name: "needsSetupConnection",
    default: true
  )

  extend(Google.Protobuf.MethodOptions, :needs_authentication, 1039,
    optional: true,
    type: :bool,
    json_name: "needsAuthentication",
    default: true
  )

  extend(Google.Protobuf.MessageOptions, :id, 1036, optional: true, type: :uint32, default: 0)

  extend(Google.Protobuf.MessageOptions, :source, 1037,
    optional: true,
    type: Espex.Proto.APISourceType,
    default: :SOURCE_BOTH,
    enum: true
  )

  extend(Google.Protobuf.MessageOptions, :ifdef, 1038, optional: true, type: :string)

  extend(Google.Protobuf.MessageOptions, :log, 1039, optional: true, type: :bool, default: true)

  extend(Google.Protobuf.MessageOptions, :no_delay, 1040,
    optional: true,
    type: :bool,
    json_name: "noDelay",
    default: false
  )

  extend(Google.Protobuf.MessageOptions, :base_class, 1041,
    optional: true,
    type: :string,
    json_name: "baseClass"
  )

  extend(Google.Protobuf.FieldOptions, :field_ifdef, 1042,
    optional: true,
    type: :string,
    json_name: "fieldIfdef"
  )

  extend(Google.Protobuf.FieldOptions, :fixed_array_size, 50007,
    optional: true,
    type: :uint32,
    json_name: "fixedArraySize"
  )

  extend(Google.Protobuf.FieldOptions, :fixed_array_skip_zero, 50009,
    optional: true,
    type: :bool,
    json_name: "fixedArraySkipZero",
    default: false
  )

  extend(Google.Protobuf.FieldOptions, :fixed_array_size_define, 50010,
    optional: true,
    type: :string,
    json_name: "fixedArraySizeDefine"
  )

  extend(Google.Protobuf.FieldOptions, :fixed_array_with_length_define, 50011,
    optional: true,
    type: :string,
    json_name: "fixedArrayWithLengthDefine"
  )

  extend(Google.Protobuf.FieldOptions, :pointer_to_buffer, 50012,
    optional: true,
    type: :bool,
    json_name: "pointerToBuffer",
    default: false
  )

  extend(Google.Protobuf.FieldOptions, :container_pointer, 50001,
    optional: true,
    type: :string,
    json_name: "containerPointer"
  )

  extend(Google.Protobuf.FieldOptions, :fixed_vector, 50013,
    optional: true,
    type: :bool,
    json_name: "fixedVector",
    default: false
  )

  extend(Google.Protobuf.FieldOptions, :container_pointer_no_template, 50014,
    optional: true,
    type: :string,
    json_name: "containerPointerNoTemplate"
  )

  extend(Google.Protobuf.FieldOptions, :packed_buffer, 50015,
    optional: true,
    type: :bool,
    json_name: "packedBuffer",
    default: false
  )
end

defmodule Espex.Proto.Void do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto2
end
