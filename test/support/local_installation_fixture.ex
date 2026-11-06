defmodule NativeArtifact.Test.LocalInstallationFixture do
  @moduledoc false

  alias NativeArtifact.Test.LocalArchiveFixture, as: ArchiveFixture

  @manifest Path.expand("../fixtures/manifest-v1.json", __DIR__)

  def create(root, opts \\ []) do
    body = Keyword.get(opts, :body, "opaque NIF bytes")

    files = [
      ArchiveFixture.file("lib/codec.so", body, role: "nif"),
      ArchiveFixture.file("LICENSE", "MIT", role: "license"),
      ArchiveFixture.file("receipt.json", "payload-owned metadata", role: "metadata")
    ]

    tar =
      ArchiveFixture.tar([
        ArchiveFixture.entry("lib/codec.so", body),
        ArchiveFixture.entry("LICENSE", "MIT"),
        ArchiveFixture.entry("receipt.json", "payload-owned metadata")
      ])

    {archive_path, operational} = ArchiveFixture.write(root, files, tar)
    data = @manifest |> File.read!() |> JSON.decode!()

    artifact =
      data["artifacts"]
      |> hd()
      |> Map.merge(operational)
      |> put_in(["archive", "filename"], "fixture.tar.gz")
      |> Map.put("private_libraries", [])

    data = Map.put(data, "artifacts", [artifact])
    priv = Path.join(root, "priv")
    File.mkdir!(priv)

    %{
      manifest: data,
      artifact: artifact,
      artifact_id: artifact["id"],
      archive_path: archive_path,
      priv: priv,
      final:
        Path.join([
          priv,
          "native",
          data["package"],
          data["package_version"],
          artifact["id"],
          artifact["archive"]["sha256"]
        ])
    }
  end
end
