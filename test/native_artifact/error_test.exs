defmodule NativeArtifact.ErrorTest do
  use ExUnit.Case, async: true

  alias NativeArtifact.Error

  test "errors preserve structured failure context without selecting recovery" do
    assert %Error{
             code: :header_limit_exceeded,
             details: %{stage: :connect, limit: 65_536}
           } = Error.new(:header_limit_exceeded, %{stage: :connect, limit: 65_536})

    assert %Error{code: :checksum_mismatch, details: %{}} = Error.new(:checksum_mismatch)
    refute :auto in Error.codes()
    refute :fallback_to_source in Error.codes()
  end
end
