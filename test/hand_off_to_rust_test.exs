defmodule HandOffToRustTest do
  use ExUnit.Case
  doctest HandOffToRust

  test "application starts" do
    assert Process.whereis(HandOffToRust.Supervisor) != nil
  end
end
