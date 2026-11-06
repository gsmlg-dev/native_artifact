defmodule NativeArtifact.ResolutionFixture do
  @moduledoc false
  alias NativeArtifact.Target

  def manifest do
    Path.expand("../fixtures/manifest-v1.json", __DIR__)
    |> File.read!()
    |> JSON.decode!()
  end

  def artifact(id \\ "codec-linux-x86_64-gnu") do
    [artifact] = manifest()["artifacts"]
    Map.put(artifact, "id", id)
  end

  def with_artifacts(artifacts), do: Map.put(manifest(), "artifacts", artifacts)

  def evidence do
    {:ok, target} = Target.new(%{"os" => "linux", "arch" => "x86_64", "libc" => "glibc"})

    %{
      target: target,
      nif: {2, 17},
      erts: "16.2",
      os_version: nil,
      libc_version: "2.31",
      vm_variant: "beam",
      system_libraries: %{
        "libc.so.6" => %{symbols: ["malloc"], symbol_versions: ["GLIBC_2.28", "GLIBC_2.31"]}
      },
      binding: artifact()["binding"]
    }
  end
end
