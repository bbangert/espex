defmodule EspexTest do
  use ExUnit.Case, async: true

  doctest Espex

  test "module is loadable" do
    assert Code.ensure_loaded?(Espex)
  end
end
